import AppKit
import CaptureStore

/// What the person is doing, as it changes: the app and window in front, and whether they're
/// active, idle or locked. A capture is written only when one of those changes, so a session is
/// the stretch from one to the next. An excluded window keeps its time and state, never its app
/// or window: a session can see a lock, or time in something private, without learning what it was.
final class ActivityCapturer {
    /// What the system says the person is doing at one moment.
    struct Sensed {
        var locked: Bool
        /// Seconds since the last input.
        var idle: TimeInterval
        /// The app in front, when unlocked.
        var app: (name: String, bundle: String?)?
        /// The title of its front-most window; empty when there's none, or no Screen Recording.
        var window: String
    }

    private let store: CaptureStore
    private let log: @Sendable (String) -> Void
    private let sense: () -> Sensed
    private var last: String?

    /// Without input for this long, the person is idle.
    static let idleAfter: TimeInterval = 120

    init(store: CaptureStore, log: @escaping @Sendable (String) -> Void, sense: @escaping () -> Sensed = ActivityCapturer.system) {
        self.store = store
        self.log = log
        self.sense = sense
    }

    /// Called on each tick while capturing, and while locked; `fragments` is the user's exclusion
    /// list. Without Screen Recording there are no window titles, so a window excluded by its title
    /// can't be told apart: nothing but the lock is noted until there are.
    func tick(fragments: [String], seesScreen: Bool) {
        // When it was seen, taken before anything is read: a Forget that lands while it's read
        // forgets a moment that includes this, and the store refuses it, rather than taking it
        // stamped after the Forget.
        let observedAt = Date()
        let sensed = sense()
        if !seesScreen && !sensed.locked {
            last = nil
            return
        }
        let state = sensed.locked ? "locked" : sensed.idle >= Self.idleAfter ? "idle" : "active"
        let app = sensed.locked ? nil : sensed.app
        let window = sensed.locked ? "" : sensed.window

        let excluded = state == "locked" || app.map { Exclusion.isExcluded(app: $0.name, window: window, fragments: fragments) } ?? false
        // The same shape the fake sensor writes (packages/schema/src/fake-sensor.js).
        let content: [String: Any] = excluded
            ? ["state": state, "excluded": true]
            : ["app": app?.name ?? "", "window": Redact.redact(window), "state": state]
        guard let text = try? String(decoding: JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), as: UTF8.self),
              text != last else { return }

        do {
            try store.append(NewCapture(
                capturedAt: observedAt, captureType: "activity", source: "activity", sourceApp: excluded ? nil : app?.bundle ?? app?.name,
                contentText: text, extraction: "none"))
            last = text
        } catch StoreError.revoked {
            log("append.refused_revoked kind=activity")
        } catch {
            log("activity.store_failed")
        }
    }

    /// Capture was held (paused, asleep, another user): the next tick records afresh.
    func reset() {
        last = nil
    }

    /// What this Mac says now. The app and window are read only while unlocked.
    static func system() -> Sensed {
        if screenLocked() { return Sensed(locked: true, idle: 0, app: nil, window: "") }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard let front = NSWorkspace.shared.frontmostApplication else { return Sensed(locked: false, idle: idle, app: nil, window: "") }
        return Sensed(locked: false, idle: idle, app: (front.localizedName ?? "", front.bundleIdentifier),
                      window: frontWindowTitle(pid: front.processIdentifier))
    }

    /// The title of the app's front-most real window, from the window list (needs Screen
    /// Recording, as every title does); empty when there's none.
    private static func frontWindowTitle(pid: pid_t) -> String {
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
