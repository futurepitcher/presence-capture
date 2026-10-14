import CryptoKit
import Foundation
import XCTest
@testable import CaptureStore

/// Sensor plugins' observations (ADR 0007), held to packages/schema/cases/observations.json as
/// the reference is, and put through the same gate.
final class GateTests: XCTestCase {
    private func cases() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../schema/cases/observations.json").standardizedFileURL
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testValidatesHeadersAsTheCasesSay() throws {
        for c in try XCTUnwrap(cases()["headers"] as? [[String: Any]]) {
            XCTAssertEqual(Observations.headerError(c["header"]) == nil, c["valid"] as? Bool, c["why"] as? String ?? "valid")
        }
    }

    func testValidatesObservationsAsTheCasesSay() throws {
        for c in try XCTUnwrap(cases()["observations"] as? [[String: Any]]) {
            XCTAssertEqual(Observations.error(c["observation"]) == nil, c["valid"] as? Bool, c["why"] as? String ?? "valid")
        }
    }

    func testDerivesTheDedupeKeyAsTheSharedVectorSays() throws {
        for v in try XCTUnwrap(cases()["dedupe_vectors"] as? [[String: Any]]) {
            let hex = try XCTUnwrap(v["master_key_hex"] as? String)
            let bytes = stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(data: bytes))
            XCTAssertEqual(store.dedupeKey(source: v["source"] as! String, value: v["value"] as! String), v["dedupe_key"] as? String)
        }
    }

    func testRefusesAnObservationStampedInTheFutureAndKeepsNamesShort() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let gate = Gate(store: store, source: "sensor:clock")
        try gate.ingest(["at": "2200-01-01T00:00:00Z", "kind": "screen", "app": "Notes", "window": "Plans", "text": "from the future"], fragments: [])
        XCTAssertEqual(gate.stats.invalid, 1, "nothing could Forget a capture stamped in the future")
        let soon = CaptureStore.iso(Date().addingTimeInterval(60))
        try gate.ingest(["at": soon, "kind": "activity", "app": "No\ntes" + String(repeating: "x", count: 1000), "window": "Plans", "state": "active"], fragments: [])
        XCTAssertEqual(gate.stats.appended, 1, "a clock a little fast is still kept")
        let app = try XCTUnwrap(store.rows("SELECT source_app FROM capture_event").first?.optionalText(0))
        XCTAssertEqual(app.unicodeScalars.count, Gate.nameLength)
        XCTAssertTrue(app.hasPrefix("Notesxxx"), app)
    }

    func testKeepsAMarkedObservationOnceEvenAfterItsRevoked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let gate = Gate(store: store, source: "sensor:git-activity")
        let commit: [String: Any] = ["at": "2026-10-06T09:00:05Z", "kind": "activity", "app": "git", "window": "repo — x", "state": "active", "dedupe": "abc123"]
        try gate.ingest(commit, fragments: [])
        try gate.ingest(commit, fragments: [])
        XCTAssertEqual(gate.stats, Gate.Stats(appended: 1, duplicates: 1))
        try store.revoke(scopeKind: "source", scopeValue: "sensor:git-activity")
        try gate.ingest(commit, fragments: [])
        XCTAssertEqual(gate.stats.appended, 1, "a revoked observation came back")
    }

    func testExcludesRedactsAndSealsUnderTheSensorsName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let gate = Gate(store: store, source: "sensor:git-activity")
        let at = "2026-10-06T09:00:05.000Z"
        try gate.ingest(["at": at, "kind": "activity", "app": "git", "window": "repo — rotate sk-ant-api03-abcdefghijklmnopqrstuvwx", "state": "active"], fragments: [])
        try gate.ingest(["at": at, "kind": "screen", "app": "Arc", "window": "Chase — Accounts", "text": "balance"], fragments: ["chase"])
        try gate.ingest(["at": at, "kind": "keystrokes", "text": "hunter2"], fragments: [])
        XCTAssertEqual(gate.stats, Gate.Stats(appended: 1, excluded: 1, redacted: 1, invalid: 1))

        let revoked = try store.revoke(scopeKind: "source", scopeValue: "sensor:git-activity")
        XCTAssertEqual(revoked.revokedCaptureIds.count, 1, "a sensor's captures revoke together by its source")
    }

    private func events(_ store: CaptureStore) throws -> Int {
        try store.rows("SELECT COUNT(*) FROM capture_event").first?.int(0) ?? -1
    }

    func testAudioWhoseTranscriptFailsLeavesNoSegmentAndItsRetryLandsWhole() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let gate = Gate(store: store)
        let heard: [String: Any] = ["at": "2026-10-06T09:00:00.000Z", "kind": "audio", "device": "input",
                                    "transcript": "we agreed to ship on friday", "dedupe": "utterance-1"]

        // The transcript's write fails (a full disk, say) after its segment's.
        try store.exec("CREATE TEMP TRIGGER transcript_fails BEFORE INSERT ON capture_event WHEN NEW.capture_type = 'audio_transcript' BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        XCTAssertThrowsError(try gate.ingest(heard, fragments: []))
        XCTAssertEqual(try events(store), 0, "a segment was kept without its transcript")

        try store.exec("DROP TRIGGER transcript_fails")
        try gate.ingest(heard, fragments: [])
        XCTAssertEqual(gate.stats, Gate.Stats(appended: 2), "the retry was taken for a duplicate, or didn't land whole")
        let rows = try store.rows("SELECT capture_id, derived_from FROM capture_event ORDER BY sequence")
        XCTAssertEqual(rows[1].optionalText(1), rows[0].text(0), "the transcript isn't derived from its segment")
        XCTAssertEqual(try store.contentText(rows[1].text(0)), "we agreed to ship on friday")
    }

    func testAnObservationStampedInsideAForgottenRangeIsRefusedNotTakenForADuplicate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let gate = Gate(store: store)
        try store.revoke(scopeKind: "time_range", scopeValue: "2026-10-06T08:55:00Z/2026-10-06T09:10:00Z")

        try gate.ingest(["at": "2026-10-06T09:00:00.000Z", "kind": "audio", "device": "input", "transcript": "said", "dedupe": "u-2"], fragments: [])
        try gate.ingest(["at": "2026-10-06T09:01:00.000Z", "kind": "screen", "app": "Notes", "window": "Plans", "text": "read"], fragments: [])
        XCTAssertEqual(gate.stats, Gate.Stats(refused: 2))
        XCTAssertEqual(try events(store), 0)
    }
}
