@testable import CaptureCore
@testable import CaptureStore
import CoreGraphics
import CryptoKit
import Foundation
@testable import PresenceCapture
import XCTest

/// A dictation from key-down to typed and kept, with a fake microphone, panel and typing (R2b): and
/// cancelled at each step it can be (starting, finishing, tidying), for each reason, with nothing
/// typed or kept and the microphone off.
@MainActor
@available(macOS 26, *)
final class DictationFlowTests: XCTestCase {
    /// Holds its words until released, so a test can act while the dictation is finishing.
    final class Session: DictationHearing {
        /// nil: there was no transcriber to hear it.
        var words: String? = "send the deck on friday"
        var holding = false
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var cancelled = false
        var waiting: Bool { gate != nil }

        func finish() async -> String? {
            if holding { await withCheckedContinuation { gate = $0 } }
            return words
        }

        func release() {
            gate?.resume()
            gate = nil
        }

        func cancel() { cancelled = true }
    }

    final class Listener: DictationListening {
        var session = Session()
        private(set) var listening = false
        private(set) var begun = 0
        private(set) var downloads = 0
        func prepare(download: Bool) { if download { downloads += 1 } }
        func begin(level: @escaping @Sendable (Float) -> Void) throws -> DictationHearing {
            begun += 1
            listening = true
            return session
        }
        func stop() { listening = false }
    }

    final class Panel: DictationShowing {
        var held: String?
        var said: String?
        func listening(_ level: Float) {}
        func working() {}
        func hold(_ text: String) { held = text }
        func say(_ message: String) { said = message }
        func hide() {}
    }

    /// Holds a proposal until released.
    final class Tidy {
        var holding = false
        private var gate: CheckedContinuation<Void, Never>?
        var waiting: Bool { gate != nil }
        func propose(_ text: String) async -> String? {
            if holding { await withCheckedContinuation { gate = $0 } }
            return text.prefix(1).uppercased() + text.dropFirst() + "."
        }
        func release() {
            gate?.resume()
            gate = nil
        }
    }

    /// What dictation sees of the focus and the front window, set by the test, read off the main thread.
    final class Where: @unchecked Sendable {
        private let lock = NSLock()
        private var now = DictationSample(focus: DictationFocus(app: "com.apple.TextEdit", element: 1, security: .open),
                                          app: FrontApp(name: "TextEdit", bundle: "com.apple.TextEdit", pid: 1), window: "Notes")
        private var front: FrontApp?
        private var switchTo: FrontApp?
        private var lost = false
        private var revoke = false
        private var revoked = false
        /// The microphone or Input Monitoring is taken away while the next sample is taken.
        func revokeWhileSampling() { lock.withLock { revoke = true } }
        var permissionGone: Bool { lock.withLock { revoked } }
        var sample: DictationSample {
            get { lock.withLock { now } }
            set { lock.withLock { now = newValue } }
        }
        /// The app in front: the sample's, unless another came to the front.
        var app: FrontApp? {
            get { lock.withLock { front ?? now.app } }
            set { lock.withLock { front = newValue } }
        }
        /// Another app comes to the front as the next sample is taken (while it waits on the app).
        func switchWhileSampling(to app: FrontApp) { lock.withLock { switchTo = app } }
        private var times: [Date] = []
        /// The moments the samples were timed from, in order.
        var since: [Date] { lock.withLock { times } }
        func sampled(_ since: Date = Date()) -> DictationSample {
            lock.withLock {
                times.append(since)
                if let to = switchTo { (front, switchTo) = (to, nil) }
                if revoke { (revoked, revoke) = (true, false) }
                return now
            }
        }
        /// The field has lost the focus just before typing, though samples still show it.
        var focusLost: Bool {
            get { lock.withLock { lost } }
            set { lock.withLock { lost = newValue } }
        }
    }

    /// Holds the read of the focus just before typing, until the test lets it answer.
    final class FocusRead: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var on = false
        var holding: Bool {
            get { lock.withLock { on } }
            set { lock.withLock { on = newValue } }
        }
        func pass() {
            guard holding else { return }
            entered.signal()
            go.wait()
        }
    }

    static let safari = FrontApp(name: "Safari", bundle: "com.apple.Safari", pid: 3)

    private var dir: URL!
    private var store: CaptureStore!
    private var listener = Listener()
    private var panel = Panel()
    private var tidy = Tidy()
    private var typed: [String] = []
    /// A paste waiting its turn, when the test holds it.
    private var waitingPaste: (text: String, check: (@escaping (Bool) -> Void) -> Void, done: (String?) -> Void)?
    /// The microphone and Input Monitoring, as the test has them.
    private var allowed = true
    private var holdPastes = false
    /// Typing asks `proceed` off the main thread, as Accessibility does.
    private var proceedOffMain = false
    private var focusRead = FocusRead()
    private var spans = DictationSpans()
    private var place = Where()
    /// What dictation says holds pastes back (a dictation being heard).
    private var pastesWait: (() -> Bool)?
    private var fragments: [String]? = []
    private var isHeld = false
    private var defaults: UserDefaults!
    private let fn = CGEventFlags.maskSecondaryFn.rawValue

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        defaults = UserDefaults(suiteName: "dictation-flow-\(UUID().uuidString)")
        (listener, panel, tidy, typed, place, fragments, isHeld, holdPastes, waitingPaste, allowed) = (Listener(), Panel(), Tidy(), [], Where(), [], false, false, nil, true)
        (proceedOffMain, focusRead, spans) = (false, FocusRead(), DictationSpans())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func dictation() throws -> Dictation {
        let (tidy, place, focusRead) = (self.tidy, self.place, self.focusRead)
        let parts = DictationParts(listener: listener, panel: panel, front: { place.app }, sample: { _, since in place.sampled(since) },
                                   tidy: { await tidy.propose($0) },
                                   type: { [unowned self] text, _, check, proceed, done in
                                       check { allowed in
                                           guard allowed else { return done(nil) }
                                           if self.holdPastes { return self.waitingPaste = (text, check, done) }
                                           if self.proceedOffMain {
                                               // Only touched again on the main actor.
                                               nonisolated(unsafe) let test = self
                                               return DispatchQueue.global().async {
                                                   let go = proceed()
                                                   Task { @MainActor in
                                                       guard go else { return done(nil) }
                                                       test.typed.append(text)
                                                       done("test")
                                                   }
                                               }
                                           }
                                           guard proceed() else { return done(nil) }
                                           self.typed.append(text)
                                           done("test")
                                       }
                                   },
                                   canType: { true }, allowed: { [unowned self] in allowed && !place.permissionGone }, secureInput: { false },
                                   stillFocused: { focus, _ in
                                       focusRead.pass()
                                       return !place.focusLost && place.sample.focus == focus
                                   },
                                   finishTyping: {}, pasteWaitWhile: { [unowned self] in pastesWait = $0 }, keyDown: { _ in true },
                                   // The key is pressed at test times (0, then 2): polls while it's held are at 1.
                                   uptime: { 1 })
        return Dictation(store: store, spans: spans, defaults: defaults, held: { [unowned self] in isHeld },
                         paused: { [unowned self] in isHeld }, fragments: { [unowned self] in fragments }, log: { _ in }, parts: parts)
    }

    /// The paste held back, made now: its check is asked as its turn comes.
    private func takeTurn() async {
        guard let paste = waitingPaste else { return }
        waitingPaste = nil
        var answer: Bool?
        paste.check { answer = $0 }
        await until { answer != nil }
        if answer == true {
            typed.append(paste.text)
            paste.done("test")
        } else {
            paste.done(nil)
        }
    }

    private func kept() throws -> Int {
        try store.rows("SELECT COUNT(*) FROM capture_event WHERE source = 'dictation'").first?.int(0) ?? -1
    }

    /// Lets anything the dictation started run its course.
    private func settle() async {
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Lets the dictation's finishing run until `done` holds.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testHeldSpokenAndReleasedItsTypedAndKept() async throws {
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        XCTAssertTrue(listener.listening)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        XCTAssertFalse(listener.listening, "the microphone stayed on after release")
        await until { !typed.isEmpty }
        XCTAssertEqual(typed, ["Send the deck on friday."])
        dictation.flush()
        XCTAssertEqual(try kept(), 1)
    }

    func testAHoldPastAPollIsStillADictation() async throws {
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        // Long enough for the poll that reads the key while it's held to run.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(listener.listening, "a held key was cancelled by its poll")
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { !typed.isEmpty }
        XCTAssertEqual(typed, ["Send the deck on friday."])
    }

    func testAFocusThatMovedTypesNothingButKeepsWhatWasSaid() async throws {
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        await settle()
        place.sample.focus = DictationFocus(app: "com.apple.Safari", element: 2, security: .open)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { panel.held != nil }
        XCTAssertEqual(typed, [])
        XCTAssertEqual(panel.held, "Send the deck on friday.")
        dictation.flush()
        XCTAssertEqual(try kept(), 1, "what was said wasn't kept")
    }

    private let reasons: [DictationCancel] = [.locked, .paused, .turnedOff, .permissionLost]

    func testCancelledWhileStartingNothingIsTypedOrKept() async throws {
        for why in reasons {
            try await setUp()
            let dictation = try dictation()
            dictation.press(keyCode: 63, flags: fn, at: 0)
            dictation.cancel(why)
            XCTAssertFalse(listener.listening, "\(why): the microphone stayed on")
            XCTAssertTrue(listener.session.cancelled, "\(why)")
            dictation.press(keyCode: 63, flags: 0, at: 2)
            await settle()
            dictation.flush()
            XCTAssertEqual(typed, [], "\(why)")
            XCTAssertEqual(try kept(), 0, "\(why)")
        }
    }

    func testCancelledWhileFinishingNothingIsTypedOrKept() async throws {
        for why in reasons {
            try await setUp()
            let dictation = try dictation()
            listener.session.holding = true
            dictation.press(keyCode: 63, flags: fn, at: 0)
            dictation.press(keyCode: 63, flags: 0, at: 2)
            await until { listener.session.waiting }
            dictation.cancel(why)
            listener.session.release()
            await settle()
            dictation.flush()
            XCTAssertEqual(typed, [], "\(why): typed after it was cancelled")
            XCTAssertEqual(try kept(), 0, "\(why): kept after it was cancelled")
        }
    }

    func testCancelledWhileTidyingNothingIsTypedOrKept() async throws {
        for why in reasons {
            try await setUp()
            let dictation = try dictation()
            tidy.holding = true
            dictation.press(keyCode: 63, flags: fn, at: 0)
            dictation.press(keyCode: 63, flags: 0, at: 2)
            await until { tidy.waiting }
            dictation.cancel(why)
            tidy.release()
            await settle()
            dictation.flush()
            XCTAssertEqual(typed, [], "\(why): typed after it was cancelled")
            XCTAssertEqual(try kept(), 0, "\(why): kept after it was cancelled")
        }
    }

    func testSaidInAnExcludedWindowIsNeverKeptWhereverItsReleased() async throws {
        fragments = ["bank"]
        place.sample.window = "My Bank"
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        await settle()
        // Moved to an ordinary window before release: the text isn't typed, and still not kept.
        place.sample = DictationSample(focus: DictationFocus(app: "com.apple.TextEdit", element: 9, security: .open),
                                       app: FrontApp(name: "TextEdit", bundle: "com.apple.TextEdit", pid: 1), window: "Notes")
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { panel.held != nil }
        dictation.flush()
        XCTAssertEqual(try kept(), 0, "what was said in an excluded window was kept")
    }

    func testAWindowTitleThatCantBeReadKeepsNothingWhenThereIsAListToMatch() async throws {
        fragments = ["bank"]
        place.sample.window = nil
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { !typed.isEmpty }
        dictation.flush()
        XCTAssertEqual(try kept(), 0)
    }

    func testReleasedInAPasswordFieldNothingIsTypedEvenIfTheFocusComesBack() async throws {
        let dictation = try dictation()
        listener.session.holding = true
        dictation.press(keyCode: 63, flags: fn, at: 0)
        await settle()
        let field = place.sample.focus
        place.sample.focus = DictationFocus(app: "com.apple.TextEdit", element: 7, security: .secure)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await settle()
        place.sample.focus = field
        listener.session.release()
        await settle()
        dictation.flush()
        XCTAssertEqual(typed, [], "a dictation released in a password field was typed")
        XCTAssertEqual(try kept(), 0)
    }

    func testAFieldThatCantBeIdentifiedIsNeverPastedInto() async throws {
        place.sample.focus = DictationFocus(app: "com.apple.TextEdit", element: nil, security: .open)
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { panel.held != nil }
        XCTAssertEqual(typed, [])
    }

    func testAPasteWaitingItsTurnIsCancelledByPause() async throws {
        holdPastes = true
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { waitingPaste != nil }
        isHeld = true
        dictation.cancel(.paused)
        await takeTurn()
        await settle()
        dictation.flush()
        XCTAssertEqual(typed, [], "a paste was made after Pause")
        XCTAssertEqual(try kept(), 0)
    }

    func testAPermissionTakenAwayWhileFinishingStopsItWithoutACancel() async throws {
        let dictation = try dictation()
        listener.session.holding = true
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { listener.session.waiting }
        allowed = false
        listener.session.release()
        await settle()
        dictation.flush()
        XCTAssertEqual(typed, [], "typed after the microphone or Input Monitoring was taken away")
        XCTAssertEqual(try kept(), 0)
    }

    func testAFieldWhoseSecurityIsUnknownIsNeitherTypedNorKept() async throws {
        place.sample.focus = DictationFocus(app: "com.apple.TextEdit", element: 1, security: .unknown)
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await settle()
        dictation.flush()
        XCTAssertEqual(typed, [])
        XCTAssertNil(panel.held, "the words were shown for a field that might be a password field")
        XCTAssertEqual(try kept(), 0, "a dictation into a field that might be a password field was kept")
    }

    func testThisAppsOwnWindowIsNeverKeptEvenWithAnEmptyList() async throws {
        place.sample = DictationSample(focus: DictationFocus(app: "ai.presenceos.capture", element: 4, security: .open),
                                       app: FrontApp(name: "Presence Capture", bundle: "ai.presenceos.capture", pid: 2), window: "Welcome to Presence Capture")
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { !typed.isEmpty }
        dictation.flush()
        XCTAssertEqual(try kept(), 0, "a dictation into this app's own window was kept")
    }

    func testAShortPressIsNotADictation() async throws {
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 0.1)
        XCTAssertFalse(listener.listening)
        await settle()
        XCTAssertEqual(typed, [])
        XCTAssertEqual(spans.verdict(at: Date().addingTimeInterval(-0.3), seconds: 0.3, now: Date()), .keep,
                       "speech around a tap of the key was dropped as dictated")
    }

    func testTheFieldsAtKeyDownAndReleaseAreTimedFromTheKeyEventsNotFromWhenTheyreRead() async throws {
        let dictation = try dictation()
        let beforeDown = Date()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        let afterDown = Date()
        try await Task.sleep(nanoseconds: 50_000_000)
        let beforeUp = Date()
        dictation.press(keyCode: 63, flags: 0, at: 2)
        let afterUp = Date()
        await until { !typed.isEmpty }
        let since = place.since
        XCTAssertGreaterThanOrEqual(since.count, 2)
        XCTAssertTrue((beforeDown...afterDown).contains(since[0]), "the key-down sample wasn't timed from key-down")
        XCTAssertTrue((beforeUp...afterUp).contains(since[1]), "the release sample wasn't timed from the release")
    }

    func testPastesWaitWhileADictationIsBeingHeard() async throws {
        let dictation = try dictation()
        XCTAssertEqual(pastesWait?(), false)
        dictation.press(keyCode: 63, flags: fn, at: 0)
        XCTAssertEqual(pastesWait?(), true, "a paste could save the clipboard while the microphone is on")
        dictation.press(keyCode: 63, flags: 0, at: 2)
        XCTAssertEqual(pastesWait?(), false)
        await until { !typed.isEmpty }
    }

    func testAnotherAppComingToTheFrontWhileTheFieldIsCheckedTypesNothing() async throws {
        // The app that was in front keeps its own focus on the field: only the app in front tells.
        for during in [false, true] {
            try await setUp()
            holdPastes = true
            let dictation = try dictation()
            dictation.press(keyCode: 63, flags: fn, at: 0)
            dictation.press(keyCode: 63, flags: 0, at: 2)
            await until { waitingPaste != nil }
            if during { place.switchWhileSampling(to: Self.safari) } else { place.app = Self.safari }
            await takeTurn()
            await settle()
            dictation.flush()
            XCTAssertEqual(typed, [], "typed into the app behind (switched \(during ? "while sampling" : "before"))")
            XCTAssertEqual(panel.held, "Send the deck on friday.", "an ordinary move holds the words")
            XCTAssertEqual(try kept(), 1)
        }
    }

    func testAPermissionTakenAwayWhileThePastesFieldIsReadPastesNothing() async throws {
        holdPastes = true
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { waitingPaste != nil }
        place.revokeWhileSampling()
        await takeTurn()
        await settle()
        dictation.flush()
        XCTAssertEqual(typed, [], "pasted after the microphone or Input Monitoring was taken away")
        XCTAssertEqual(try kept(), 0)
    }

    func testACancelWhileTheFocusIsReadLeavesTheFieldAlone() async throws {
        proceedOffMain = true
        focusRead.holding = true
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { focusRead.entered.wait(timeout: .now()) == .success }
        // Paused while Accessibility waits on the app, which then answers that the field has the focus.
        isHeld = true
        dictation.cancel(.paused)
        focusRead.go.signal()
        await settle()
        dictation.flush()
        XCTAssertEqual(typed, [], "the field was changed after the dictation was cancelled")
        XCTAssertEqual(try kept(), 0)
    }

    func testMovedToAPasswordFieldWhileAPasteWaitedNothingIsShownOrKept() async throws {
        for security in [DictationFocus.Security.secure, .unknown] {
            try await setUp()
            holdPastes = true
            let dictation = try dictation()
            dictation.press(keyCode: 63, flags: fn, at: 0)
            dictation.press(keyCode: 63, flags: 0, at: 2)
            await until { waitingPaste != nil }
            place.sample.focus = DictationFocus(app: "com.apple.TextEdit", element: 7, security: security)
            await takeTurn()
            await settle()
            dictation.flush()
            XCTAssertEqual(typed, [], "\(security)")
            XCTAssertNil(panel.held, "\(security): the words were shown")
            XCTAssertEqual(panel.said, "Nothing is typed into a password field.", "\(security)")
            XCTAssertEqual(try kept(), 0, "\(security): kept")
        }
    }

    func testAFocusThatCantBeConfirmedJustBeforeTypingIsTakenAsAPasswordField() async throws {
        place.focusLost = true
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { panel.said != nil }
        dictation.flush()
        XCTAssertEqual(typed, [])
        XCTAssertNil(panel.held)
        XCTAssertEqual(try kept(), 0)
    }

    func testNoTranscriberSaysSoAndFetchesTheModel() async throws {
        listener.session.words = nil
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 2)
        await until { panel.said != nil }
        dictation.flush()
        XCTAssertTrue(panel.said?.contains("speech model") == true)
        XCTAssertEqual(listener.downloads, 1, "the model wasn't asked for")
        XCTAssertEqual(typed, [])
        XCTAssertEqual(try kept(), 0)
    }
}
