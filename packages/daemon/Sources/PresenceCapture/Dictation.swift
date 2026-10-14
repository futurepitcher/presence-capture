import AppKit
import AVFoundation
import CaptureCore
import CaptureStore

/// What the app asks of dictation, whatever macOS it runs on.
protocol Dictating: AnyObject {
    /// The settings changed (on or off, the key): the key's listener started or stopped to match.
    func apply()
    /// Capture is held (locked, asleep, another user, paused): any dictation stops, with nothing kept.
    func cancel(_ why: DictationCancel)
    /// Each tick: a permission taken away stops it.
    func check()
    /// Quitting.
    func stop()
}

/// The microphone and transcriber, as dictation uses them: DictationListener, or a fake in tests.
protocol DictationListening: AnyObject {
    func prepare(download: Bool)
    func begin(level: @escaping @Sendable (Float) -> Void) throws -> DictationHearing
    func stop()
}

/// One dictation's words: DictationSession, or a fake in tests.
protocol DictationHearing: AnyObject {
    func finish() async -> String?
    func cancel()
}

/// The panel: DictationPanel, or a fake in tests.
protocol DictationShowing: AnyObject {
    func listening(_ level: Float)
    func working()
    func hold(_ text: String)
    func say(_ message: String)
    func hide()
}

/// What dictation works with, apart from the store: the real ones by default, fakes in tests.
@available(macOS 26, *)
struct DictationParts {
    var listener: DictationListening
    var panel: DictationShowing = DictationPanel()
    var focus: () -> DictationFocus = Focus.now
    var front: () -> ActivityCapturer.Sensed = ActivityCapturer.system
    var tidy: (String) async -> String? = { await Tidier.propose($0) }
    /// Typing in; says how, for the log.
    var type: (String, DictationFocus) -> String
    var canType: () -> Bool = AXIsProcessTrusted
}

/// Dictation's settings, in the app's defaults.
enum DictationSettings {
    static func on(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: "dictation") }
    static func key(_ defaults: UserDefaults) -> DictationKey { DictationKey(rawValue: defaults.string(forKey: "dictationKey") ?? "") ?? .fn }
    /// On by default (maintainer, 2026-10-14).
    static func remember(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: "rememberDictation") as? Bool ?? true }
    static func tidy(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: "tidyDictation") as? Bool ?? true }

    /// What macOS itself does with the Globe key, when it does something: a dictation held on Fn
    /// would set it off too. Read, never changed.
    static func globeClash() -> String? {
        switch UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int {
        case 0: return nil
        case 1: return "changes the input source"
        case 2: return "shows Emoji & Symbols"
        case 3: return "starts Apple's own Dictation"
        default: return "may do something of its own"
        }
    }
}

/// Push to talk into any app (R2b): hold the key, speak, release, and what was said is typed where
/// the cursor is, transcribed on this Mac with the same Transcriber ambient audio uses. A dictation
/// always ends: released, or cancelled (held too long, the screen locking, Pause, turned off, a
/// permission taken away), and every step after checks its token, so a cancelled one does nothing.
/// Used from the main thread.
@available(macOS 26, *)
final class Dictation: Dictating {
    private let defaults: UserDefaults
    private let store: CaptureStore
    private let spans: DictationSpans
    private let log: @Sendable (String) -> Void
    /// Whether capture is held now (paused, locked, asleep, another user): the key does nothing.
    private let held: () -> Bool
    private let paused: () -> Bool
    /// The person's exclusion list, nil when it can't be read (then nothing is kept, R8).
    private let fragments: () -> [String]?
    /// Stores are written here, never on the main thread.
    private let writer = DispatchQueue(label: "presence.capture.dictation")

    private var hold: DictationHold
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var poller: Timer?
    private let parts: DictationParts
    private var listener: DictationListening { parts.listener }
    private var panel: DictationShowing { parts.panel }

    /// Dictations under way, by token: listening, or being finished.
    private var live: [Int: Live] = [:]
    /// The one the microphone is on for.
    private var listening: Int?

    private struct Live {
        let began: Date
        let focus: DictationFocus
        let session: DictationHearing
    }

    init(store: CaptureStore, spans: DictationSpans, defaults: UserDefaults = .standard, held: @escaping () -> Bool,
         paused: @escaping () -> Bool, fragments: @escaping () -> [String]?, log: @escaping @Sendable (String) -> Void,
         parts: DictationParts? = nil) {
        (self.store, self.spans, self.defaults, self.held, self.paused, self.fragments, self.log) = (store, spans, defaults, held, paused, fragments, log)
        hold = DictationHold(key: DictationSettings.key(defaults))
        self.parts = parts ?? Self.realParts(log: log)
    }

    /// The microphone, the panel, Accessibility and the clipboard, as the app uses them.
    private static func realParts(log: @escaping @Sendable (String) -> Void) -> DictationParts {
        let inserter = Inserter(paster: ClipboardPaster(
            pasteboard: SystemClipboard(), paste: Inserter.postPaste,
            schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }))
        return DictationParts(listener: DictationListener(log: log),
                              type: { text, focus in inserter.type(text, into: focus.element as? AXElement).rawValue })
    }

    // MARK: For tests

    /// A `flagsChanged` event for the key, as the tap would give it.
    func press(keyCode: Int64, flags: UInt64, at time: TimeInterval) {
        act(hold.flagsChanged(keyCode: keyCode, flags: flags, at: time))
    }

    /// Returns once every dictation queued to be kept is written.
    func flush() {
        writer.sync {}
    }

    static var allowed: (microphone: Bool, inputMonitoring: Bool, accessibility: Bool) {
        (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, CGPreflightListenEventAccess(), AXIsProcessTrusted())
    }

    func apply() {
        act(hold.setKey(DictationSettings.key(defaults)))
        let allowed = Self.allowed
        if DictationSettings.on(defaults), allowed.microphone, allowed.inputMonitoring {
            startTap()
            listener.prepare(download: true)
        } else {
            cancelAll(.turnedOff)
            stopTap()
        }
    }

    func cancel(_ why: DictationCancel) {
        cancelAll(why)
    }

    func check() {
        guard DictationSettings.on(defaults) else { return }
        let allowed = Self.allowed
        if !allowed.microphone || !allowed.inputMonitoring {
            if tap != nil { log("dictation.permission_lost") }
            cancelAll(.permissionLost)
            stopTap()
        } else if tap == nil {
            apply()
        }
    }

    func stop() {
        cancelAll(.turnedOff)
        stopTap()
    }

    // MARK: The key

    private func startTap() {
        guard tap == nil else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: DictationKey.eventMask, callback: dictationTapCallback, userInfo: me) else {
            log("dictation.tap_failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        (self.tap, self.source) = (tap, source)
        log("dictation.on key=\(hold.key.rawValue)")
    }

    private func stopTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        (self.tap, self.source) = (nil, nil)
        log("dictation.off")
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned the tap off: a release may have been missed. On again; any dictation stops.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("dictation.tap_reenabled")
            cancelAll(.tapDisabled)
        case .flagsChanged:
            act(hold.flagsChanged(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue,
                                  at: ProcessInfo.processInfo.systemUptime))
        default:
            break
        }
    }

    private func act(_ action: HoldAction) {
        switch action {
        case .none: break
        case .begin(let token): begin(token)
        case .end(let token): end(token)
        case .cancel(let token, let why): drop(token, why)
        }
    }

    // MARK: A dictation

    private func begin(_ token: Int) {
        // Held (paused, locked): the key does nothing.
        guard !held() else { return act(hold.cancel(.paused)) }
        let began = Date()
        spans.began(at: began)
        do {
            let panel = self.panel
            let session = try listener.begin(level: { level in DispatchQueue.main.async { panel.listening(level) } })
            live[token] = Live(began: began, focus: parts.focus(), session: session)
            listening = token
            startPolling()
            // Shown once it's a dictation, not an ordinary press of the key.
            DispatchQueue.main.asyncAfter(deadline: .now() + DictationHold.shortest) { [weak self] in
                if self?.listening == token { self?.panel.listening(0) }
            }
        } catch {
            log("dictation.mic_failed")
            act(hold.cancel(.permissionLost))
            spans.ended(at: Date())
        }
    }

    private func end(_ token: Int) {
        stopPolling()
        spans.ended(at: Date())
        if listening == token {
            listener.stop()
            listening = nil
        }
        guard let dictation = live[token] else { return }
        panel.working()
        Task { @MainActor [weak self] in await self?.finish(token, dictation) }
    }

    /// Stops `token` with nothing typed or kept: the microphone off at once, its words let go.
    private func drop(_ token: Int, _ why: DictationCancel) {
        stopPolling()
        spans.ended(at: Date())
        if listening == token {
            listener.stop()
            listening = nil
        }
        guard let dictation = live.removeValue(forKey: token) else { return }
        dictation.session.cancel()
        panel.hide()
        if why != .tooShort { log("dictation.cancelled why=\(why.rawValue)") }
        listener.prepare(download: false)
    }

    private func cancelAll(_ why: DictationCancel) {
        act(hold.cancel(why))
        for token in Array(live.keys) { drop(token, why) }
    }

    private func startPolling() {
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: DictationHold.pollEvery, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.act(self.hold.poll(flags: CGEventSource.flagsState(.combinedSessionState).rawValue, at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func stopPolling() {
        poller?.invalidate()
        poller = nil
    }

    /// Released: the words, tidied if they may be, typed in if the focus is where it was, and kept
    /// if they may be. Each step checks the dictation is still live.
    @MainActor private func finish(_ token: Int, _ dictation: Live) async {
        let heard = await dictation.session.finish() ?? ""
        guard live[token] != nil else { return }
        var text = DictationText.spokenCommands(heard)
        let front = parts.front()
        let app = front.app?.bundle ?? dictation.focus.app
        if DictationSettings.tidy(defaults), !text.isEmpty, !DictationText.neverTidied.contains(app), let proposal = await parts.tidy(text) {
            guard live[token] != nil else { return }
            if DictationText.tidyKeepsMeaning(proposal, of: text) { text = proposal } else { log("dictation.tidy_refused") }
        }
        guard live.removeValue(forKey: token) != nil else { return }
        defer { listener.prepare(download: false) }
        guard !text.isEmpty else { return panel.hide() }

        let now = parts.focus()
        let typing = DictationOutcome.typing(began: dictation.focus, now: now)
        switch typing {
        case .type where !parts.canType():
            panel.hold(text)
            log("dictation.no_accessibility")
        case .type:
            let way = parts.type(text, now)
            panel.hide()
            log("dictation.typed way=\(way)")
        case .focusMoved:
            panel.hold(text)
            log("dictation.focus_moved")
        case .secure:
            panel.say("Nothing is typed into a password field.")
            log("dictation.secure_field")
        }

        let excluded = fragments().map { fragments in
            front.app.map { Exclusion.isExcluded(app: $0.name, window: front.window, fragments: fragments) } ?? false
        } ?? true
        if let skip = DictationOutcome.skip(remember: DictationSettings.remember(defaults), excluded: excluded,
                                            secure: typing == .secure, cancelled: false, paused: paused()) {
            log("dictation.not_kept why=\(skip.rawValue)")
            return
        }
        let (store, log, began, sourceApp) = (self.store, self.log, dictation.began, excluded ? nil : app)
        writer.async { Self.keep(text, began: began, app: sourceApp, store: store, log: log) }
    }

    /// A dictation kept as said (R2b): an `audio_transcript` with source `dictation`, stamped at
    /// key-down (H6), so one stamped inside a forgotten range is refused (R13). Redacted as stored.
    static func keep(_ text: String, began: Date, app: String?, store: CaptureStore, log: (String) -> Void) {
        do {
            try store.append(NewCapture(capturedAt: began, captureType: "audio_transcript", source: "dictation", sourceApp: app,
                                        contentText: Redact.redact(text), extraction: "asr"))
            log("dictation.kept")
        } catch StoreError.revoked {
            log("append.refused_revoked kind=dictation")
        } catch {
            log("dictation.store_failed")
        }
    }
}

/// The event tap's callback: modifier changes, on the main run loop.
@available(macOS 26, *)
private func dictationTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let info { Unmanaged<Dictation>.fromOpaque(info).takeUnretainedValue().handle(type, event) }
    return Unmanaged.passUnretained(event)
}
