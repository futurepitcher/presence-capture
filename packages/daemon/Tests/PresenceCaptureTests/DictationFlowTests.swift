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

    private var dir: URL!
    private var store: CaptureStore!
    private var listener = Listener()
    private var panel = Panel()
    private var tidy = Tidy()
    private var typed: [String] = []
    private var focus = DictationFocus(app: "com.apple.TextEdit", element: 1, secure: false)
    private var defaults: UserDefaults!
    private let fn = CGEventFlags.maskSecondaryFn.rawValue

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        defaults = UserDefaults(suiteName: "dictation-flow-\(UUID().uuidString)")
        (listener, panel, tidy, typed) = (Listener(), Panel(), Tidy(), [])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func dictation() throws -> Dictation {
        let tidy = self.tidy
        let parts = DictationParts(listener: listener, panel: panel, focus: { [unowned self] in focus },
                                   front: { .init(locked: false, idle: 0, app: ("TextEdit", "com.apple.TextEdit"), window: "Notes") },
                                   tidy: { await tidy.propose($0) }, type: { [unowned self] text, _ in typed.append(text); return "test" },
                                   canType: { true })
        return Dictation(store: store, spans: DictationSpans(), defaults: defaults, held: { false }, paused: { false },
                         fragments: { [] }, log: { _ in }, parts: parts)
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
        focus = DictationFocus(app: "com.apple.Safari", element: 2, secure: false)
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

    func testAShortPressIsNotADictation() async throws {
        let dictation = try dictation()
        dictation.press(keyCode: 63, flags: fn, at: 0)
        dictation.press(keyCode: 63, flags: 0, at: 0.1)
        XCTAssertFalse(listener.listening)
        await settle()
        XCTAssertEqual(typed, [])
    }
}
