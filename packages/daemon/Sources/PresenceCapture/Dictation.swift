import AppKit
import AVFoundation
import Carbon.HIToolbox
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
    /// Quitting: every dictation stops, nothing more is typed, and a clipboard a paste is holding is
    /// put back now.
    func stop()
    /// Returns once what dictation had accepted to keep is written (quitting).
    func drained() async
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
    /// The app in front, on the main thread.
    var front: () -> FrontApp? = FrontApp.now
    /// Where typing would go, asked off the main thread (Accessibility can wait on an app).
    var sample: @Sendable (FrontApp?) -> DictationSample = { Focus.sample($0) }
    var tidy: (String) async -> String? = { await Tidier.propose($0) }
    /// Typing in: `check` is asked (and answers on the main thread) before anything is typed or
    /// pasted; `proceed` is asked off the main thread just before Accessibility changes the field;
    /// `done` hears how it went in, or nil when it wasn't.
    var type: (String, DictationFocus, @escaping (@escaping (Bool) -> Void) -> Void, @escaping () -> Bool, @escaping (String?) -> Void) -> Void
    var canType: () -> Bool = AXIsProcessTrusted
    /// The permissions dictation needs to go on: the microphone, and Input Monitoring for the key.
    var allowed: () -> Bool = { let a = Dictation.allowed; return a.microphone && a.inputMonitoring }
    /// Secure Event Input, read on the main thread at key-down and release (cheap, no app asked).
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    /// Whether the field is still the one with the app's focus, asked off the main thread just
    /// before Accessibility changes it.
    var stillFocused: @Sendable (DictationFocus, FrontApp?) -> Bool = { focus, app in
        (focus.element as? AXElement).map { Focus.stillFocused($0.element, in: app) } ?? false
    }
    /// Puts back a clipboard a paste is holding, and drops pastes not yet made (quitting).
    var finishTyping: () -> Void = {}
    /// Whether the selected key is down now, by its physical key: never a modifier the other hand
    /// may also be holding.
    var keyDown: (DictationKey) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0.keyCode)) }
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
final class Dictation: Dictating, @unchecked Sendable {
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

    /// Dictations under way, by token: listening, being finished, or being typed in. One that's gone
    /// was cancelled or is done, and every later step asks.
    private var live: [Int: Live] = [:]
    /// The one the microphone is on for, and the one the panel is showing.
    private var listening: Int?
    private var shown: Int?
    /// The live tokens, readable off the main thread (Accessibility asks just before changing a field).
    private let stillLive = LockedSet()
    /// Dictations not typed because, just before, the field was, or might have been, a password field:
    /// nothing is shown or kept for them. Written on either thread.
    private let refusedSecure = LockedSet()

    private final class Live {
        let began: Date
        /// Where typing would go at key-down, and at release: asked off the main thread.
        let origin: Task<DictationSample, Never>
        var released: Task<DictationSample, Never>?
        /// Secure Event Input at key-down and at release, read then, on the main thread.
        let secureAtStart: Bool
        var secureAtRelease = false
        let session: DictationHearing

        init(began: Date, origin: Task<DictationSample, Never>, secureAtStart: Bool, session: DictationHearing) {
            (self.began, self.origin, self.secureAtStart, self.session) = (began, origin, secureAtStart, session)
        }
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
                              type: { text, focus, check, proceed, done in
                                  inserter.type(text, into: focus.element as? AXElement, check: check, proceed: proceed) { done($0?.rawValue) }
                              },
                              finishTyping: { inserter.paster.finishNow() })
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
        parts.finishTyping()
    }

    func drained() async {
        let writer = self.writer
        await withCheckedContinuation { done in writer.async { done.resume() } }
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
            // The microphone first: nothing below can hold it up.
            let session = try listener.begin(level: { [weak self] level in
                DispatchQueue.main.async { if self?.shown == token { self?.panel.listening(level) } }
            })
            let (front, sample) = (parts.front(), parts.sample)
            live[token] = Live(began: began, origin: Task.detached { sample(front) }, secureAtStart: parts.secureInput(), session: session)
            stillLive.insert(token)
            listening = token
            startPolling()
            // Shown once it's a dictation, not an ordinary press of the key.
            DispatchQueue.main.asyncAfter(deadline: .now() + DictationHold.shortest) { [weak self] in
                guard let self, self.listening == token else { return }
                self.shown = token
                self.panel.listening(0)
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
        // Where typing would go as the key comes up, before anything is waited for.
        dictation.secureAtRelease = parts.secureInput()
        let (front, sample) = (parts.front(), parts.sample)
        dictation.released = Task.detached { sample(front) }
        panel.working()
        Task { @MainActor [weak self] in await self?.finish(token, dictation) }
    }

    /// Stops `token` with nothing typed or kept: the microphone off at once, its words let go.
    private func drop(_ token: Int, _ why: DictationCancel) {
        stopPolling()
        // A tap of the key isn't a dictation: nothing was said into it, so nothing it overlaps is dropped.
        if why == .tooShort { spans.discard() } else { spans.ended(at: Date()) }
        if listening == token {
            listener.stop()
            listening = nil
        }
        guard let dictation = live.removeValue(forKey: token) else { return }
        stillLive.remove(token)
        refusedSecure.remove(token)
        dictation.session.cancel()
        // The panel is this dictation's, or no one's: never hidden from under a newer one.
        if shown == token || shown == nil {
            shown = nil
            panel.hide()
        }
        if why != .tooShort { log("dictation.cancelled why=\(why.rawValue)") }
        listener.prepare(download: false)
    }

    private func cancelAll(_ why: DictationCancel) {
        act(hold.cancel(why))
        for token in Array(live.keys) { drop(token, why) }
    }

    private func startPolling() {
        poller?.invalidate()
        let timer = Timer(timeInterval: DictationHold.pollEvery, repeats: true) { [weak self] _ in
            guard let self else { return }
            // A permission taken away stops it at once, not at the app's next tick.
            guard self.parts.allowed() else { return self.cancelAll(.permissionLost) }
            self.act(self.hold.poll(keyDown: self.parts.keyDown(self.hold.key), at: ProcessInfo.processInfo.systemUptime))
        }
        // In every mode, so menu tracking never stops it.
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    private func stopPolling() {
        poller?.invalidate()
        poller = nil
    }

    /// Whether a sample's front window is excluded, or might be. The built-in exclusions (system UI,
    /// this app) always apply; an exclusion list that can't be read, an app that isn't known, or a
    /// window title that can't be read when there's a list to match it against, keeps nothing.
    private func excluded(_ sample: DictationSample) -> Bool {
        guard let fragments = fragments(), let app = sample.app else { return true }
        if Exclusion.isExcluded(app: app.name, window: sample.window ?? "", fragments: fragments) { return true }
        return sample.window == nil && !fragments.isEmpty
    }

    /// Still this dictation, and still allowed to go on: asked before each step.
    private func going(_ token: Int) -> Bool {
        guard live[token] != nil else { return false }
        guard parts.allowed() else {
            cancelAll(.permissionLost)
            return false
        }
        return true
    }

    /// Released: the words, tidied if they may be, typed in if the focus is the same known field at
    /// key-down, at release and just before typing, and kept if they may be. Each step checks the
    /// dictation is still live; it stays live until it's typed in, so a paste waiting its turn is
    /// cancelled with it.
    @MainActor private func finish(_ token: Int, _ dictation: Live) async {
        guard let heard = await dictation.session.finish() else {
            // No transcriber to hear it: the speech model isn't on this Mac, or couldn't be made. It's
            // fetched now (dictation is on, so it may be), and the next dictation tries again.
            guard going(token) else { return }
            listener.prepare(download: true)
            panel.say("Dictation needs Apple's speech model, which isn't ready yet. It's being fetched: try again shortly.")
            log("dictation.no_transcriber")
            return done(token, hidePanel: false)
        }
        let origin = await dictation.origin.value
        let released = await (dictation.released?.value ?? origin)
        guard going(token) else { return }
        var text = DictationText.spokenCommands(heard)
        let app = origin.app?.bundle ?? origin.focus.app
        if DictationSettings.tidy(defaults), !text.isEmpty, !DictationText.neverTidied.contains(app), let proposal = await parts.tidy(text) {
            guard going(token) else { return }
            if DictationText.tidyKeepsMeaning(proposal, of: text) { text = proposal } else { log("dictation.tidy_refused") }
        }
        guard going(token) else { return }
        guard !text.isEmpty else { return done(token) }

        let (front, sample) = (parts.front(), parts.sample)
        let now = await Task.detached { sample(front) }.value
        guard going(token) else { return }
        // Kept by where it was said: excluded there, or where it was released, it's not kept; nor
        // when a field was, or might have been, a password field.
        let excluded = self.excluded(origin) || self.excluded(released)
        let secure = origin.focus.secure || released.focus.secure || dictation.secureAtStart || dictation.secureAtRelease
        let keep = { [weak self] in
            guard let self, self.parts.allowed() else { return }
            self.remember(text, began: dictation.began, origin: origin, excluded: excluded, secure: secure)
        }
        let typing = secure ? .secure : DictationOutcome.typing(began: origin.focus, released: released.focus, now: now.focus)
        switch typing {
        case .type where !parts.canType():
            panel.hold(text)
            log("dictation.no_accessibility")
            done(token, hidePanel: false)
            keep()
        case .type:
            let expected = now.focus
            let (stillLive, refusedSecure, stillFocused, app) = (self.stillLive, self.refusedSecure, parts.stillFocused, now.app)
            let (allowed, canType) = (parts.allowed, parts.canType)
            parts.type(text, expected, { [weak self] answer in
                // Before anything is typed or pasted: still this dictation, still allowed, still the app
                // in front, and still this field, read off the main thread; then all of it asked again
                // as the answer is given on the main thread, since any of it may have changed while the
                // field was read. A field that is, or might be, a password field is remembered as that.
                guard let self, self.going(token), !self.held(), self.parts.canType(), self.parts.front()?.pid == app?.pid else {
                    return answer(false)
                }
                let (front, sample) = (self.parts.front(), self.parts.sample)
                Task.detached {
                    let now = sample(front)
                    await MainActor.run { [weak self] in
                        guard let self, self.going(token), !self.held(), self.parts.canType(), self.parts.front()?.pid == app?.pid else {
                            return answer(false)
                        }
                        if self.parts.secureInput() {
                            refusedSecure.insert(token)
                            return answer(false)
                        }
                        switch DictationOutcome.typing(began: expected, released: expected, now: now.focus) {
                        case .type: answer(true)
                        case .secure:
                            refusedSecure.insert(token)
                            answer(false)
                        case .focusMoved: answer(false)
                        }
                    }
                }
            }, {
                // Off the main thread, just before Accessibility changes the field. The focus is read
                // first (it can wait on an app); then whether it's still this dictation and still
                // allowed, so a cancel that came while the read waited is seen.
                let focused = stillFocused(expected, app)
                guard stillLive.contains(token), allowed(), canType() else { return false }
                // Not the field now, and where the focus went isn't known: as if a password field.
                if !focused { refusedSecure.insert(token) }
                return focused
            }, { [weak self] way in
                guard let self, self.going(token) else { return }
                if let way {
                    self.done(token)
                    self.log("dictation.typed way=\(way)")
                    keep()
                } else if self.held() {
                    // Paused or locked while it waited: like a cancel, nothing is typed or kept.
                    self.done(token)
                    self.log("dictation.cancelled why=paused")
                } else if refusedSecure.contains(token) {
                    // Moved to a field that is, or might be, a password field: nothing shown or kept.
                    self.panel.say("Nothing is typed into a password field.")
                    self.log("dictation.secure_field")
                    self.done(token, hidePanel: false)
                } else {
                    self.panel.hold(text)
                    self.done(token, hidePanel: false)
                    self.log("dictation.focus_moved")
                    keep()
                }
            })
        case .focusMoved:
            panel.hold(text)
            log("dictation.focus_moved")
            done(token, hidePanel: false)
            keep()
        case .secure:
            panel.say("Nothing is typed into a password field.")
            log("dictation.secure_field")
            done(token, hidePanel: false)
        }
    }

    /// The dictation is over: nothing after this can cancel it.
    private func done(_ token: Int, hidePanel: Bool = true) {
        live.removeValue(forKey: token)
        stillLive.remove(token)
        refusedSecure.remove(token)
        let mine = shown == token || shown == nil
        if shown == token { shown = nil }
        if hidePanel && mine { panel.hide() }
        listener.prepare(download: false)
    }

    private func remember(_ text: String, began: Date, origin: DictationSample, excluded: Bool, secure: Bool) {
        if let skip = DictationOutcome.skip(remember: DictationSettings.remember(defaults), excluded: excluded,
                                            secure: secure, cancelled: false, paused: paused()) {
            log("dictation.not_kept why=\(skip.rawValue)")
            return
        }
        let (store, log, app) = (self.store, self.log, excluded ? nil : origin.app?.bundle)
        writer.async { Self.keep(text, began: began, app: app, store: store, log: log) }
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

/// A set of tokens, read and written from any thread.
final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens = Set<Int>()
    func insert(_ token: Int) { lock.withLock { _ = tokens.insert(token) } }
    func remove(_ token: Int) { lock.withLock { _ = tokens.remove(token) } }
    func contains(_ token: Int) -> Bool { lock.withLock { tokens.contains(token) } }
}
