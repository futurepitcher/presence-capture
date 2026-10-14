import AppKit
import ApplicationServices
import CaptureCore
import CaptureStore
import ScreenCaptureKit

/// Every tick, each on-screen window of the frontmost app, kept as text: the focused one read from
/// the app's Accessibility tree where it exposes enough (exact, and no OCR), the rest with Vision:
/// excluded first (nothing of an excluded window is read), then deduplicated (a window whose image
/// hasn't changed since it was last kept is not kept again, R7), then redacted and sealed into the
/// store. No image is ever written (ADR 0005). An actor: a capture, and Vision's reading, run off
/// the main thread, one at a time.
actor ScreenCapturer {
    private let store: CaptureStore
    private let log: @Sendable (String) -> Void
    private var busy = false
    /// Paused, the screens asleep or another user's session: set by the app on the main thread and
    /// read here at once, not through this actor (which a capture under way holds, in Accessibility
    /// or OCR, for as long as they take).
    private let holding: HoldState
    /// The image hash last kept, by window: an unchanged window isn't kept again.
    private var lastKept: [CGWindowID: String] = [:]
    /// Counts for the hourly log line: never what was read.
    private(set) var frames = 0
    private(set) var reads = 0
    private(set) var readMs = 0.0
    private(set) var axReads = 0

    init(store: CaptureStore, holding: HoldState = HoldState(), log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.holding = holding
        self.log = log
    }

    func takeCounts() -> (frames: Int, reads: Int, readMs: Double, axReads: Int) {
        defer { frames = 0; reads = 0; readMs = 0; axReads = 0 }
        return (frames, reads, readMs, axReads)
    }

    func hold(_ held: Bool) {
        holding.set(held)
    }

    /// Whether a window may be captured now: not held, and not locked (the windows behind the lock
    /// screen are still on screen to ScreenCaptureKit).
    private var mayCapture: Bool { !holding.now.held && !screenLocked() }

    /// Still as the batch began: it may capture, it hasn't been held since (even if it was let go
    /// again: what was read across a Pause isn't kept), and the app is still in front.
    private func stillOn(_ pid: pid_t, since holds: Int) -> Bool {
        let now = holding.now
        return !now.held && now.holds == holds && !screenLocked() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
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
        let holds = holding.now.holds
        // Remembered while a window is on screen at all, so switching apps and back keeps nothing twice.
        let onScreen = Set(content.windows.map(\.windowID))
        lastKept = lastKept.filter { onScreen.contains($0.key) }
        for window in windows {
            let title = window.title ?? ""
            // Exclusion before any bytes exist (R8): an excluded window is never captured at all.
            if Exclusion.isExcluded(app: app, window: title, fragments: fragments) { continue }
            guard stillOn(pid, since: holds) else { break }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let info = SCShareableContent.info(for: filter)
            let config = SCStreamConfiguration()
            config.width = Int(info.contentRect.width * CGFloat(info.pointPixelScale))
            config.height = Int(info.contentRect.height * CGFloat(info.pointPixelScale))
            config.showsCursor = false
            // When it was seen, taken before the image is, and kept through reading it: a Forget that
            // lands while it's taken or read forgets a moment that includes this, and the store
            // refuses it, rather than taking it stamped after the Forget.
            let observedAt = Date()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            // Locked, held or another app in front while it was taken (it may show what's behind the
            // lock screen): not kept, and the rest wait for the next tick.
            guard stillOn(pid, since: holds) else { break }
            // Retitled while it was taken (another tab, perhaps one the list excludes): what it
            // shows may not be what its title says. Not kept, not even read.
            guard currentTitle(window.windowID) == title else { continue }
            let hash = OCR.hash(image)
            // Unchanged since it was last kept: dropped, not stored (R7).
            if lastKept[window.windowID] == hash { continue }
            let focused = window.windowID == FrontWindow.of(Set(windows.map(\.windowID)), pid: pid, frontToBack: listedWindows())
            // The app's own text first, where it exposes it for this window: exact, and no OCR.
            // Only the focused window can be read this way, and only what's visible in it.
            var text: String?
            var extraction = "ocr"
            if focused, let read = AXReader.focusedWindow(pid: pid, title: title, deadline: Date().addingTimeInterval(0.5)),
               let visible = AXText.visibleText(read.root, window: read.frame) {
                text = visible
                extraction = "accessibility"
                axReads += 1
            }
            if text == nil {
                let started = Date()
                text = try OCR.read(image).map(\.text).joined(separator: "\n")
                reads += 1
                readMs += Date().timeIntervalSince(started) * 1000
            }
            guard stillOn(pid, since: holds), currentTitle(window.windowID) == title, let text else { continue }
            // Nothing in it to keep: remembered as read, so an unchanged blank window isn't read again.
            guard !text.isEmpty else {
                lastKept[window.windowID] = hash
                continue
            }
            // A page's address only where the browser says it (never inferred from what's on screen),
            // and only for this window: its focused window must be the one read, by title, and it
            // must still be in front with that title once the address is read. A tab switched
            // meanwhile gives no address rather than another page's.
            var url: String?
            if focused, AXIsProcessTrusted(), let page = pageAddress(pid: pid, title: title) {
                guard stillOn(pid, since: holds), currentTitle(window.windowID) == title,
                      window.windowID == FrontWindow.of(Set(windows.map(\.windowID)), pid: pid, frontToBack: listedWindows()) else { continue }
                url = page
            }
            // Held (Pause, the lock) while it was read, however briefly: not kept. Nothing below waits.
            guard stillOn(pid, since: holds) else { break }
            do {
                try store.append(NewCapture(
                    capturedAt: observedAt, captureType: "screen_text", source: "screen", sourceApp: front.bundleIdentifier ?? app,
                    sourceUrl: url, contentText: Redact.redact(text), extraction: extraction))
            } catch StoreError.revoked {
                log("append.refused_revoked kind=screen")
                continue
            }
            // Remembered only once it's kept: a window whose text was refused (its moment was
            // forgotten), or not written at all, is read again while it's on screen.
            lastKept[window.windowID] = hash
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
    /// browser's. Only when that window's title is `title`, the window that was read; none
    /// otherwise, and none without Accessibility.
    private func pageAddress(pid: pid_t, title: String) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        let element = window as! AXUIElement
        var focusedTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &focusedTitle) == .success,
              focusedTitle as? String == title else { return nil }
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

/// Whether capture is held, and how many times it has been: set by the app on the main thread as it
/// holds or lets go, and read by a capture under way between and after its reads, so a Pause is
/// seen at once, and work begun before a hold is never kept after it, even once it's let go.
final class HoldState: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var holds = 0

    func set(_ held: Bool) {
        lock.withLock {
            if held && !self.held { holds += 1 }
            self.held = held
        }
    }

    var now: (held: Bool, holds: Int) { lock.withLock { (held, holds) } }
}
