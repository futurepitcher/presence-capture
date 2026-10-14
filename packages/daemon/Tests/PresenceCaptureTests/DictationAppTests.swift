@testable import CaptureCore
@testable import CaptureStore
import CryptoKit
import Foundation
@testable import PresenceCapture
import XCTest

/// Dictation in the app (R2b): what's kept, and what ambient audio drops because of it.
final class DictationAppTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        var lines: [String] { lock.withLock { all } }
        func write(_ line: String) { lock.withLock { all.append(line) } }
    }

    func testADictationIsKeptAsSaidAndRefusedInsideAForgottenRange() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        let log = Lines()
        let began = Date().addingTimeInterval(-30)
        Dictation.keep("Email dana@example.com about the export", began: began, app: "com.apple.TextEdit", store: store, log: log.write)
        let row = try XCTUnwrap(store.rows("SELECT capture_id, captured_at, capture_type, source, source_app, extraction FROM capture_event").first)
        XCTAssertEqual([row.text(2), row.text(3), row.text(4), row.text(5)], ["audio_transcript", "dictation", "com.apple.TextEdit", "asr"])
        XCTAssertEqual(row.text(1), CaptureStore.iso(began), "not stamped at key-down")
        XCTAssertEqual(try store.contentText(row.text(0)), "Email [EMAIL] about the export", "not redacted as stored")

        // Forgotten while it was being finished: refused (R13).
        let now = Date()
        _ = try store.revoke(scopeKind: "time_range", scopeValue: "\(CaptureStore.iso(now.addingTimeInterval(-60)))/\(CaptureStore.iso(now))")
        Dictation.keep("said in the forgotten minute", began: now.addingTimeInterval(-10), app: nil, store: store, log: log.write)
        XCTAssertEqual(log.lines, ["dictation.kept", "append.refused_revoked kind=dictation"])
    }

    func testAmbientAudioDropsWhatWasDictatedFromTheMicrophoneOnly() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        let spans = DictationSpans()
        let t0 = Date()
        spans.began(at: t0)
        spans.ended(at: t0.addingTimeInterval(4))
        let said = Spoken(at: t0.addingTimeInterval(1), seconds: 2, device: "Mic (input)", deviceType: "input", text: "hello")
        let played = Spoken(at: t0.addingTimeInterval(1), seconds: 2, device: "System Audio (output)", deviceType: "output", text: "hello")
        XCTAssertEqual(AudioCapturer.admits(said, spans: spans, now: t0.addingTimeInterval(5)), .dictated)
        XCTAssertEqual(AudioCapturer.admits(played, spans: spans, now: t0.addingTimeInterval(5)), .keep, "what a call said was dropped")
        XCTAssertEqual(AudioCapturer.admits(played, spans: spans, now: t0.addingTimeInterval(700)), .tooLate)
    }
}
