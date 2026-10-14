import CoreGraphics
import Foundation

/// The key held to dictate (R2b): Fn (Globe) by default, or Right Option or Right Command.
public enum DictationKey: String, CaseIterable, Sendable {
    case fn
    case rightOption = "right-option"
    case rightCommand = "right-command"

    public var name: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    /// The key's code in a `flagsChanged` event: which modifier changed.
    public var keyCode: Int64 {
        switch self {
        case .fn: return 63 // kVK_Function
        case .rightOption: return 61 // kVK_RightOption
        case .rightCommand: return 54 // kVK_RightCommand
        }
    }

    /// Whether the key is down in these flags (an event's, or the system's): Fn by its own flag, the
    /// right-hand keys by their device bits, so the left-hand ones never start a dictation.
    public func isDown(_ flags: UInt64) -> Bool {
        switch self {
        case .fn: return flags & CGEventFlags.maskSecondaryFn.rawValue != 0
        case .rightOption: return flags & 0x40 != 0 // NX_DEVICERALTKEYMASK
        case .rightCommand: return flags & 0x10 != 0 // NX_DEVICERCMDKEYMASK
        }
    }

    /// What the event tap asks for: `flagsChanged`, and nothing else. It never sees a key typed.
    public static let eventMask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
}

/// Why a dictation ended without being typed or kept.
public enum DictationCancel: String, Sendable, Equatable {
    /// Released within `DictationHold.shortest`: an ordinary press of the key, not a dictation.
    case tooShort
    /// Held past `DictationHold.longest`.
    case tooLong
    /// The key to hold was changed while it was held.
    case keyChanged
    case locked
    case paused
    case turnedOff
    case permissionLost
    /// macOS turned the event tap off: a release may have been missed.
    case tapDisabled
}

/// What a change in the key means.
public enum HoldAction: Sendable, Equatable {
    case none
    /// The key went down: start listening, as dictation `token`.
    case begin(Int)
    /// The key came up after long enough: finish dictation `token` and type it in.
    case end(Int)
    /// Dictation `token` stops here, with nothing typed or kept.
    case cancel(Int, DictationCancel)
}

/// Holding the key, as a state machine with the time given, so a test can drive it: down begins a
/// dictation with a token of its own, up ends it. A dictation always ends: a release macOS never
/// delivers is caught by `poll`, which reads the key from the system while it's held, and one held
/// too long is cancelled. Every later step checks its token, so a cancelled dictation does nothing.
public struct DictationHold: Sendable {
    /// A hold shorter than this is a press of the key, not a dictation.
    public static let shortest: TimeInterval = 0.25
    /// Held longer, it's cancelled: a stuck key, or someone who forgot.
    public static let longest: TimeInterval = 120
    /// How often `poll` should be called while the key is held.
    public static let pollEvery: TimeInterval = 0.25

    public private(set) var key: DictationKey
    private var held: (token: Int, since: TimeInterval)?
    private var lastToken = 0

    public init(key: DictationKey) {
        self.key = key
    }

    /// The dictation under way, if one is.
    public var token: Int? { held?.token }

    /// A `flagsChanged` event: the key that changed, and the flags after it.
    public mutating func flagsChanged(keyCode: Int64, flags: UInt64, at now: TimeInterval) -> HoldAction {
        guard keyCode == key.keyCode else { return .none }
        if key.isDown(flags) {
            guard held == nil else { return .none }
            lastToken += 1
            held = (lastToken, now)
            return .begin(lastToken)
        }
        return release(at: now)
    }

    /// The key as the system has it now, read while it's held (the physical key, by its code: never a
    /// modifier the other hand may also be holding): a release that never came as an event is a
    /// release all the same. And a hold past `longest` is cancelled.
    public mutating func poll(keyDown: Bool, at now: TimeInterval) -> HoldAction {
        guard let held else { return .none }
        if now - held.since >= Self.longest { return cancel(.tooLong) }
        return keyDown ? .none : release(at: now)
    }

    /// Stops the dictation under way, for `why`.
    public mutating func cancel(_ why: DictationCancel) -> HoldAction {
        guard let held else { return .none }
        self.held = nil
        return .cancel(held.token, why)
    }

    /// A different key from now on; a dictation held with the old one is cancelled.
    public mutating func setKey(_ new: DictationKey) -> HoldAction {
        guard new != key else { return .none }
        let action = cancel(.keyChanged)
        key = new
        return action
    }

    /// Released: too soon is a press, too late (the poll missed it) is over the cap, else a dictation.
    private mutating func release(at now: TimeInterval) -> HoldAction {
        guard let held else { return .none }
        self.held = nil
        let length = now - held.since
        if length < Self.shortest { return .cancel(held.token, .tooShort) }
        return length >= Self.longest ? .cancel(held.token, .tooLong) : .end(held.token)
    }
}
