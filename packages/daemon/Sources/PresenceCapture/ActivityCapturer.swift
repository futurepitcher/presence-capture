import AppKit
import CaptureStore

/// What the person is doing, as it changes: the app and window in front, and whether they're
/// active, idle or locked. A capture is written only when one of those changes, so a session is
/// the stretch from one to the next. An excluded window keeps its time and state, never its app
/// or window: a session can see a lock, or time in something private, without learning what it was.
final class ActivityCapturer {
    private let store: CaptureStore
    private let log: @Sendable (String) -> Void
    private var last: String?

    /// Without input for this long, the person is idle.
    static let idleAfter: TimeInterval = 120

    init(store: CaptureStore, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.log = log
    }

    /// Called on each tick while capturing, and while locked; `fragments` is the user's exclusion
    /// list. Without Screen Recording there are no window titles, so a window excluded by its title
    /// can't be told apart: nothing but the lock is noted until there are.
    func tick(fragments: [String], seesScreen: Bool) {
        if !seesScreen && !screenLocked() {
            last = nil
            return
        }
        let state: String
        var app: (name: String, bundle: String?)?
        var window = ""
        if screenLocked() {
            state = "locked"
        } else {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            state = idle >= Self.idleAfter ? "idle" : "active"
            if let front = NSWorkspace.shared.frontmostApplication {
                app = (front.localizedName ?? "", front.bundleIdentifier)
                window = frontWindowTitle(pid: front.processIdentifier)
            }
        }

        let excluded = state == "locked" || app.map { Exclusion.isExcluded(app: $0.name, window: window, fragments: fragments) } ?? false
        // The same shape the fake sensor writes (packages/schema/src/fake-sensor.js).
        let content: [String: Any] = excluded
            ? ["state": state, "excluded": true]
            : ["app": app?.name ?? "", "window": Redact.redact(window), "state": state]
        guard let text = try? String(decoding: JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), as: UTF8.self),
              text != last else { return }

        do {
            try store.append(NewCapture(
                captureType: "activity", source: "activity", sourceApp: excluded ? nil : app?.bundle ?? app?.name,
                contentText: text, extraction: "none"))
            last = text
        } catch {
            log("activity.store_failed")
        }
    }

    /// Capture was held (paused, asleep, another user): the next tick records afresh.
    func reset() {
        last = nil
    }

    /// The title of the app's front-most real window, from the window list (needs Screen
    /// Recording, as every title does); empty when there's none.
    private func frontWindowTitle(pid: pid_t) -> String {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard bounds.width >= 100, bounds.height >= 60 else { continue }
            return info[kCGWindowName as String] as? String ?? ""
        }
        return ""
    }
}
