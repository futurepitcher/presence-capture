import Foundation

/// The clipboard, as the paster needs it: NSPasteboard in the app, a fake in tests.
public protocol Clipboard: AnyObject {
    /// Goes up with every write, by anyone.
    var changeCount: Int { get }
    /// Every item, every type, as it is now.
    func snapshot() -> [[String: Data]]
    /// Puts items back as they were.
    func restore(_ items: [[String: Data]])
    /// Replaces what's there with `text`.
    func write(_ text: String)
}

/// Typing text in by pasting, without losing the person's clipboard (R2b). One paste at a time: the
/// clipboard is saved, the text written and pasted, and `restoreAfter` later the saved items go back,
/// but only if the clipboard still holds the dictation's own write. If anything else copied
/// meanwhile, it's left as it is. A second paste waits until the first has restored (or left) the
/// clipboard, so what it saves is always the person's own, never a dictation's.
///
/// Used from one thread (the app's main thread); `schedule` runs its work later on that thread.
public final class ClipboardPaster {
    public static let restoreAfter: TimeInterval = 0.75

    private let pasteboard: Clipboard
    private let paste: () -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var queue: [(text: String, done: (Bool) -> Void)] = []
    private var busy = false

    /// `paste` posts ⌘V; `schedule` runs a closure after a delay.
    public init(pasteboard: Clipboard, paste: @escaping () -> Void,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.pasteboard = pasteboard
        self.paste = paste
        self.schedule = schedule
    }

    /// Pastes `text`; `done` hears whether the person's clipboard was put back (false when something
    /// else copied meanwhile, and it was left as it is).
    public func paste(_ text: String, done: @escaping (Bool) -> Void = { _ in }) {
        queue.append((text, done))
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let (text, done) = queue.removeFirst()
        let saved = pasteboard.snapshot()
        pasteboard.write(text)
        let ours = pasteboard.changeCount
        paste()
        schedule(Self.restoreAfter) { [self] in
            let restored = pasteboard.changeCount == ours
            if restored { pasteboard.restore(saved) }
            busy = false
            done(restored)
            next()
        }
    }
}

/// Where typing is going: the front app and its focused element. Compared at key-down and at
/// release; if it moved, nothing is typed.
public struct DictationFocus: Equatable {
    public let app: String
    /// The focused element, as something comparable (an AXUIElement in the app, by CFEqual).
    public let element: AnyHashable?
    /// A password field, or Secure Event Input on: nothing is typed or kept.
    public let secure: Bool

    public init(app: String, element: AnyHashable?, secure: Bool) {
        (self.app, self.element, self.secure) = (app, element, secure)
    }
}

/// Whether to type a dictation in, and whether to keep it (R2b).
public enum DictationOutcome {
    public enum Typing: Equatable {
        case type
        /// The front app or focused element changed: nothing is typed, and nothing is written to the
        /// clipboard. The panel keeps the text, with a Copy button.
        case focusMoved
        /// A secure field: nothing is typed, and the panel holds no text.
        case secure
    }

    public static func typing(began: DictationFocus, now: DictationFocus) -> Typing {
        if began.secure || now.secure { return .secure }
        return began.app == now.app && began.element == now.element ? .type : .focusMoved
    }

    public enum Skip: String, Equatable {
        case rememberOff = "remember_off"
        case excluded
        case secure
        case cancelled
        case paused
    }

    /// Why a dictation isn't kept, or nil when it is. A dictation not typed because focus moved is
    /// still kept: it was said.
    public static func skip(remember: Bool, excluded: Bool, secure: Bool, cancelled: Bool, paused: Bool) -> Skip? {
        if cancelled { return .cancelled }
        if paused { return .paused }
        if secure { return .secure }
        if excluded { return .excluded }
        return remember ? nil : .rememberOff
    }
}
