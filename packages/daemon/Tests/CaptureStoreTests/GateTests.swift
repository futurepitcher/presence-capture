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
}
