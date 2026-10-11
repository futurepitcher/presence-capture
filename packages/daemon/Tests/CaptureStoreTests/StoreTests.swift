import CryptoKit
import Foundation
import XCTest
@testable import CaptureStore

/// Conformance is the store layer of packages/schema/conformance, driven through pcap-driver.
/// These check what that suite can't see from outside.
final class StoreTests: XCTestCase {
    func testEmbedsExactlyTheSpecsMigrations() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../schema/migrations").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".sql") }.sorted()
        XCTAssertEqual(Migrations.all.map(\.name), files, "run scripts/embed-migrations.mjs")
        for migration in Migrations.all {
            let sql = try String(contentsOf: dir.appendingPathComponent(migration.name), encoding: .utf8)
            XCTAssertEqual(migration.sql, sql, "\(migration.name) differs: run scripts/embed-migrations.mjs")
        }
    }

    func testWritesTimesAsTheReferenceDoes() throws {
        let date = try XCTUnwrap(CaptureStore.date("2026-10-06T09:00:05.120Z"))
        XCTAssertEqual(CaptureStore.iso(date), "2026-10-06T09:00:05.120Z")
        XCTAssertEqual(CaptureStore.iso(try XCTUnwrap(CaptureStore.date("2026-10-06T09:00:05Z"))), "2026-10-06T09:00:05.000Z")
    }

    func testForgetsTheLastStretchAndKeepsWhatCameBefore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let now = Date()
        let earlier = try store.append(NewCapture(capturedAt: now.addingTimeInterval(-3600), captureType: "screen_text", source: "screen", contentText: "an hour ago"))
        let recent = try store.append(NewCapture(capturedAt: now.addingTimeInterval(-300), captureType: "screen_text", source: "screen", contentText: "five minutes ago"))
        let revoked = try store.revoke(scopeKind: "time_range", scopeValue: "\(CaptureStore.iso(now.addingTimeInterval(-900)))/\(CaptureStore.iso(now))", reason: "forget")
        XCTAssertEqual(revoked.revokedCaptureIds, [recent])
        XCTAssertNil(try store.contentText(recent))
        XCTAssertEqual(try store.contentText(earlier), "an hour ago")
    }
}
