@testable import CaptureCore
@testable import CaptureStore
import CoreMedia
import CryptoKit
import Foundation
import ScreenCaptureKit
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

    /// A text field as Accessibility shows one, that can reformat what it's given.
    final class Field: TextTarget {
        var text: String
        var range: CFRange
        var readable = true
        var reformat: (String) -> String = { $0 }
        private(set) var changed = 0
        init(_ text: String, selected range: CFRange) { (self.text, self.range) = (text, range) }
        var value: String? { readable ? text : nil }
        var selection: CFRange? { readable ? range : nil }
        func setSelectedText(_ inserted: String) -> Bool {
            changed += 1
            text = (text as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: reformat(inserted))
            return true
        }
    }

    func testAnUtteranceThatEndedTheCutoffAgoIsDroppedNotStampedAsJustSaid() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        let now = Date(), clock = CMTime(seconds: 10_000, preferredTimescale: 600)
        let ended = { (ago: Double) in CMTimeRange(start: CMTime(seconds: 10_000 - ago - 2, preferredTimescale: 600),
                                                   end: CMTime(seconds: 10_000 - ago, preferredTimescale: 600)) }
        XCTAssertNil(AudioCapturer.times(ended(DictationSpans.cutoff), clockNow: clock, now: now))
        let times = try XCTUnwrap(AudioCapturer.times(ended(DictationSpans.cutoff - 1), clockNow: clock, now: now))
        XCTAssertEqual(times.end.timeIntervalSince(now), -(DictationSpans.cutoff - 1), accuracy: 0.01)
    }

    func testAFieldIsOpenOnlyWhenItsRoleAndSubroleWereReadAndNeitherIsSecure() {
        let field = Focus.Read.text("AXTextField")
        XCTAssertEqual(Focus.security(role: field, subrole: .absent), .open)
        XCTAssertEqual(Focus.security(role: field, subrole: .text("AXSearchField")), .open)
        XCTAssertEqual(Focus.security(role: field, subrole: .text("AXSecureTextField")), .secure)
        XCTAssertEqual(Focus.security(role: .text("AXSecureTextField"), subrole: .failed), .secure, "a secure role is enough")
        XCTAssertEqual(Focus.security(role: field, subrole: .failed), .unknown, "a subrole that couldn't be read was taken as open")
        XCTAssertEqual(Focus.security(role: .failed, subrole: .absent), .unknown)
        XCTAssertEqual(Focus.security(role: .absent, subrole: .absent), .unknown, "an element with no role")
    }

    func testAccessibilityInsertionIsCheckedAndNeverPastedTwice() throws {
        let field = Field("Hello world", selected: CFRange(location: 6, length: 5))
        XCTAssertEqual(Inserter.insert("there", into: field), .inserted)
        XCTAssertEqual(field.text, "Hello there")

        // A field that reformats (drops a newline, say): taken, so never pasted again.
        let single = Field("", selected: CFRange(location: 0, length: 0))
        single.reformat = { $0.replacingOccurrences(of: "\n", with: " ") }
        XCTAssertEqual(Inserter.insert("a\nb", into: single), .unchecked)

        // A field that can't be read isn't changed: it's pasted into instead, if at all.
        let blind = Field("x", selected: CFRange(location: 0, length: 0))
        blind.readable = false
        XCTAssertEqual(Inserter.insert("y", into: blind), .refused)
        XCTAssertEqual(blind.changed, 0)

        // Told not to go on, just before the change: the field isn't touched.
        let moved = Field("Hello", selected: CFRange(location: 5, length: 0))
        XCTAssertEqual(Inserter.insert(" world", into: moved, proceed: { false }), .stopped)
        XCTAssertEqual(moved.changed, 0, "the field was changed after it was told not to")
        XCTAssertEqual(moved.text, "Hello")
    }

    func testNothingHeardIsKeptWhileTheExclusionListCantBeRead() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        let readable = ReadableSince()
        let audio = AudioCapturer(store: store, devices: { (true, true) }, mayKeep: { readable.admits($0) }, log: { _ in })
        let t0 = Date()
        let rows = { try store.rows("SELECT COUNT(*) FROM capture_event").first?.int(0) }
        // Said while the list couldn't be read: not kept, even once it can be again.
        readable.observe(false, at: t0)
        let duringOutage = Spoken(at: t0.addingTimeInterval(2), seconds: 2, device: "Mic (input)", deviceType: "input", text: "the plan for friday")
        audio.keep(duringOutage, from: .microphone)
        XCTAssertEqual(try rows(), 0, "heard and kept while the exclusion list couldn't be read")
        readable.observe(true, at: t0.addingTimeInterval(10))
        audio.keep(duringOutage, from: .microphone)
        XCTAssertEqual(try rows(), 0, "speech from while the list couldn't be read got in once it could")
        // Said since it can be read: kept.
        audio.keep(Spoken(at: t0.addingTimeInterval(11), seconds: 2, device: "Mic (input)", deviceType: "input", text: "after"), from: .microphone)
        XCTAssertEqual(try rows(), 2, "the segment and its transcript")
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
