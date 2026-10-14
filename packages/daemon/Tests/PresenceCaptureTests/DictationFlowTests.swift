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
        var words = "send the deck on friday"
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
        func prepare(download: Bool) {}
        func begin(level: @escaping @Sendable (Float) -> Void) throws -> DictationHearing {
            begun += 1
            listening = true
            return session
        }
        func stop() { listening = false }
    }

    final class Panel: DictationShowing {
        var held: String?
        func listening(_ level: Float) {}
        func working() {}
        func hold(_ text: String) { held = text }
        func say(_ message: String) {}
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
        var sample: DictationSample {
            get { lock.withLock { now } }
            set { lock.withLock { now = newValue } }
        }
    }

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
    private var place = Where()
    private var fragments: [String]? = []
    private var isHeld = false
    private var defaults: UserDefaults!
    private let fn = CGEventFlags.maskSecondaryFn.rawValue

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        defaults = UserDefaults(suiteName: "dictation-flow-\(UUID().uuidString)")
        (listener, panel, tidy, typed, place, fragments, isHeld, holdPastes, waitingPaste, allowed) = (Listener(), Panel(), Tidy(), [], Where(), [], false, false, nil, true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func dictation() throws -> Dictation {
        let (tidy, place) = (self.tidy, self.place)
        let parts = DictationParts(listener: listener, panel: panel, front: { place.sample.app }, sample: { _ in place.sample },
                                   tidy: { await tidy.propose($0) },
                                   type: { [unowned self] text, _, check, proceed, done in
                                       check { allowed in
                                           guard allowed else { return done(nil) }
                                           if holdPastes { return waitingPaste = (text, check, done) }
                                           guard proceed() else { return done(nil) }
                                           typed.append(text)
                                           done("test")
                                       }
                                   },
                                   canType: { true }, allowed: { [unowned self] in allowed }, secureInput: { false },
                                   stillFocused: { focus, _ in place.sample.focus == focus }, finishTyping: {}, keyDown: { _ in true })
        return Dictation(store: store, spans: DictationSpans(), defaults: defaults, held: { [unowned self] in isHeld },
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
    }
}
