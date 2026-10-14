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
    private var queue: [(text: String, check: (@escaping (Bool) -> Void) -> Void, done: (Bool?) -> Void)] = []
    /// The restore waiting for its time, to run at once when asked (quitting).
    private var restoreNow: (() -> Void)?
    /// Quitting: nothing more is pasted, whatever a check still to answer says.
    private var stopped = false
    private var busy = false

    /// `paste` posts ⌘V; `schedule` runs a closure after a delay.
    public init(pasteboard: Clipboard, paste: @escaping () -> Void,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.pasteboard = pasteboard
        self.paste = paste
        self.schedule = schedule
    }

    /// Pastes `text` once its turn comes, if `check` still says yes then (the focus is where it was,
    /// the dictation wasn't cancelled): a paste that waited behind another is checked when it's made,
    /// not when it was asked for. `check` answers through its callback, on this thread, so it can ask
    /// elsewhere (Accessibility, off the main thread) without holding this one. `done` hears nil when
    /// it wasn't made, else whether the person's clipboard was put back (false when something else
    /// copied meanwhile, and it was left as it is).
    public func paste(_ text: String, check: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) },
                      done: @escaping (Bool?) -> Void = { _ in }) {
        guard !stopped else { return done(nil) }
        queue.append((text, check, done))
        next()
    }

    /// Puts back now a clipboard waiting for its time, and drops pastes not yet made (quitting).
    public func finishNow() {
        stopped = true
        let waiting = queue
        queue = []
        for paste in waiting { paste.done(nil) }
        restoreNow?()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let (text, check, done) = queue.removeFirst()
        check { [self] allowed in
            guard allowed, !stopped else {
                busy = false
                done(nil)
                return next()
            }
            let saved = pasteboard.snapshot()
            pasteboard.write(text)
            let ours = pasteboard.changeCount
            paste()
            var finished = false
            let restore = { [self] in
                guard !finished else { return }
                finished = true
                restoreNow = nil
                let restored = pasteboard.changeCount == ours
                if restored { pasteboard.restore(saved) }
                busy = false
                done(restored)
                next()
            }
            restoreNow = restore
            schedule(Self.restoreAfter, restore)
        }
    }
}

/// Where typing is going: the front app, its focused element, and whether it's a password field.
/// Compared at key-down, at release and just before typing; if it moved, nothing is typed.
public struct DictationFocus: Equatable {
    /// Whether the field is secure. Unknown (Accessibility didn't say) counts as secure: nothing is
    /// typed, kept or shown.
    public enum Security: Equatable {
        case open
        case secure
        case unknown
    }

    public let app: String
    /// The focused element, as something comparable (an AXUIElement in the app, by CFEqual); nil
    /// when it couldn't be read, or wasn't consistent with the front window while it was being read.
    public let element: AnyHashable?
    public let security: Security

    public init(app: String, element: AnyHashable?, security: Security) {
        (self.app, self.element, self.security) = (app, element, security)
    }

    /// Secure, or not known not to be.
    public var secure: Bool { security != .open }
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

    /// The focus at key-down, at release, and now (just before typing): typed only if all three are
    /// the same known element, each known not to be secure. A field that couldn't be identified, or
    /// whose security couldn't be told, is never typed into: secure if any is (or might be), else
    /// moved.
    public static func typing(began: DictationFocus, released: DictationFocus, now: DictationFocus) -> Typing {
        if began.secure || released.secure || now.secure { return .secure }
        guard began.element != nil, began == released, released == now else { return .focusMoved }
        return .type
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
