import AppKit
import ApplicationServices
import CaptureCore
import CaptureStore
import ScreenCaptureKit

/// Every tick, each on-screen window of the frontmost app, read with Vision (OCR) and kept as text:
/// excluded first (nothing of an excluded window is read), then deduplicated (a window whose image
/// hasn't changed since it was last kept is not kept again, R7), then redacted and sealed into the
/// store. No image is ever written (ADR 0005). An actor: a capture, and Vision's reading, run off
/// the main thread, one at a time.
actor ScreenCapturer {
    private let store: CaptureStore
    private let log: @Sendable (String) -> Void
    private var busy = false
    /// Paused, the screens asleep or another user's session: set by the app, and seen between
    /// windows too, so a capture under way stops at the next one.
    private var held = false
    /// The image hash last kept, by window: an unchanged window isn't kept again.
    private var lastKept: [CGWindowID: String] = [:]
    /// Counts for the hourly log line: never what was read.
    private(set) var frames = 0
    private(set) var reads = 0
    private(set) var readMs = 0.0

    init(store: CaptureStore, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.log = log
    }

    func takeCounts() -> (frames: Int, reads: Int, readMs: Double) {
        defer { frames = 0; reads = 0; readMs = 0 }
        return (frames, reads, readMs)
    }

    func hold(_ held: Bool) {
        self.held = held
    }

    /// Whether a window may be captured now: not held, and not locked (the windows behind the lock
    /// screen are still on screen to ScreenCaptureKit).
    private var mayCapture: Bool { !held && !screenLocked() }

    /// Still as the batch began: it may capture, and the app it's capturing is still in front.
    private func stillOn(_ pid: pid_t) -> Bool {
        mayCapture && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// One capture, unless the last is still under way or there's no permission to see the screen.
    /// `fragments` is the user's exclusion list, already read: nil when it couldn't be, and then
    /// nothing is captured.
    func tick(fragments: [String]?) async {
        guard let fragments, !busy, CGPreflightScreenCaptureAccess(), mayCapture else { return }
        busy = true
        defer { busy = false }
        do {
            try await capture(fragments: fragments)
        } catch {
            log("capture.failed \(String(describing: type(of: error)))")
        }
    }

    private func capture(fragments: [String]) async throws {
        guard let front = NSWorkspace.shared.frontmostApplication, let app = front.localizedName else { return }
        if Exclusion.isExcluded(app: app, window: "", fragments: fragments) { return }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == front.processIdentifier && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width >= FrontWindow.minWidth && $0.frame.height >= FrontWindow.minHeight
        }
        let pid = front.processIdentifier
        // Remembered while a window is on screen at all, so switching apps and back keeps nothing twice.
        let onScreen = Set(content.windows.map(\.windowID))
        lastKept = lastKept.filter { onScreen.contains($0.key) }
        for window in windows {
            let title = window.title ?? ""
            // Exclusion before any bytes exist (R8): an excluded window is never captured at all.
            if Exclusion.isExcluded(app: app, window: title, fragments: fragments) { continue }
            guard stillOn(pid) else { break }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let info = SCShareableContent.info(for: filter)
            let config = SCStreamConfiguration()
            config.width = Int(info.contentRect.width * CGFloat(info.pointPixelScale))
            config.height = Int(info.contentRect.height * CGFloat(info.pointPixelScale))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            // Locked, held or another app in front while it was taken (it may show what's behind the
            // lock screen): not kept, and the rest wait for the next tick.
            guard stillOn(pid) else { break }
            // Retitled while it was taken (another tab, perhaps one the list excludes): what it
            // shows may not be what its title says. Not kept, not even read.
            guard currentTitle(window.windowID) == title else { continue }
            let hash = OCR.hash(image)
            // Unchanged since it was last kept: dropped, not stored (R7).
            if lastKept[window.windowID] == hash { continue }
            let started = Date()
            let lines = try OCR.read(image)
            reads += 1
            readMs += Date().timeIntervalSince(started) * 1000
            guard stillOn(pid), currentTitle(window.windowID) == title else { continue }
            let text = lines.map(\.text).joined(separator: "\n")
            lastKept[window.windowID] = hash
            guard !text.isEmpty else { continue }
            let focused = window.windowID == FrontWindow.of(Set(windows.map(\.windowID)), pid: pid, frontToBack: listedWindows())
            // A page's address only where the browser says it (never inferred from what's on screen).
            let url = focused && AXIsProcessTrusted() ? pageAddress(pid: pid) : nil
            try store.append(NewCapture(
                capturedAt: Date(), captureType: "screen_text", source: "screen", sourceApp: front.bundleIdentifier ?? app,
                sourceUrl: url, contentText: Redact.redact(text), extraction: "ocr"))
            frames += 1
        }
    }

    /// A window's title as it is now, from the window list; nil once it's gone.
    private func currentTitle(_ id: CGWindowID) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        guard let info = list.first else { return nil }
        return info[kCGWindowName as String] as? String ?? ""
    }

    /// The windows on screen, front to back, from the window list.
    private func listedWindows() -> [FrontWindow.Listed] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? NSNumber, let pid = info[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return FrontWindow.Listed(
                id: CGWindowID(id.uint32Value), pid: pid.int32Value, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                width: bounds.width, height: bounds.height, alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    /// The address of the page in the app's focused window, when it says (AXDocument, or AXURL): a
    /// browser's. Needs Accessibility; none without it.
    private func pageAddress(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        let element = window as! AXUIElement
        for attribute in [kAXDocumentAttribute, "AXURL"] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { continue }
            if let text = value as? String, !text.isEmpty { return text }
            if let url = value as? URL { return url.absoluteString }
        }
        return nil
    }
}

/// Locked, the windows behind the lock screen are still on screen to ScreenCaptureKit: nothing is
/// captured then (no window, no audio, no activity but the lock itself).
func screenLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
}
