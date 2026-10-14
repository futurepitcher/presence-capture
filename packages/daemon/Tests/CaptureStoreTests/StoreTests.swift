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

    /// A range's bounds are read back from text and written again before they're compared: a
    /// millisecond lost on the way would let a capture in that millisecond out of the range.
    func testWritesATimeReadBackAsTheSameText() throws {
        for ms in 0..<1000 {
            let text = String(format: "2026-10-06T09:00:05.%03dZ", ms)
            XCTAssertEqual(CaptureStore.iso(try XCTUnwrap(CaptureStore.date(text))), text)
        }
        XCTAssertEqual(CaptureStore.iso(try XCTUnwrap(CaptureStore.date(CaptureStore.epoch))), CaptureStore.epoch)
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

    /// A failure finishing the erasure after the revocation committed is reported with the
    /// revocation, which stands, and the erasure is finished later: never "nothing was forgotten".
    func testAFailureAfterTheRevocationCommittedLeavesItStandingAndPending() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let id = try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "forgotten"))
        store.afterTruncation = { throw StoreError.sqlite("disk full") }

        let result = try store.revoke(scopeKind: "capture", scopeValue: id)
        XCTAssertEqual(result.revokedCaptureIds, [id])
        XCTAssertFalse(result.erasedOnDisk)
        XCTAssertEqual(result.erasureError, "capture store: disk full")
        XCTAssertNil(try store.contentText(id), "the revocation did not stand")
        XCTAssertTrue(store.isErasurePending)

        store.afterTruncation = nil
        XCTAssertTrue(try store.finishErasure())
    }
}

import SQLite3

final class HeldLogTests: XCTestCase {
    /// A reader in another process holding a snapshot keeps the write-ahead log from being
    /// truncated: the erasure isn't reported done, and finishes once the reader lets go.
    func testFinishesAnErasureAReaderHeldUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let store = try CaptureStore(path: path, masterKey: Seal.newKey())
        let id = try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "read while forgotten"))

        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT COUNT(*) FROM capture_event;", nil, nil, nil), SQLITE_OK)

        let revoked = try store.revoke(scopeKind: "capture", scopeValue: id)
        XCTAssertFalse(revoked.erasedOnDisk, "reported erased while a reader held the log")
        XCTAssertTrue(store.isErasurePending)
        XCTAssertFalse(try store.finishErasure(), "finished while the reader still held it")

        XCTAssertEqual(sqlite3_exec(reader, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try store.finishErasure())
        XCTAssertFalse(store.isErasurePending)
    }

    /// A writer stamps only the erasures its truncation proved: one another writer commits after it,
    /// while a reader holds the log again, stays pending until it's finished in turn.
    func testStampsOnlyTheErasuresItsTruncationProved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let key = Seal.newKey()
        let a = try CaptureStore(path: path, masterKey: key)
        let b = try CaptureStore(path: path, masterKey: key)
        let first = try a.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "first"))
        let second = try a.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "second"))
        let completed = { (rev: String) in try a.rows("SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?", rev).first?.optionalText(0) }

        var reader = try Self.pinLog(path)
        let revA = try a.revoke(scopeKind: "capture", scopeValue: first).revocationId
        reader.release()

        // After A's truncation and before it stamps: B revokes while another reader holds the log.
        var revB: String?
        a.afterTruncation = {
            a.afterTruncation = nil
            reader = try! Self.pinLog(path)
            revB = try! b.revoke(scopeKind: "capture", scopeValue: second).revocationId
        }
        _ = try a.finishErasure()
        XCTAssertNotNil(try completed(revA), "A's erasure, which its truncation proved, wasn't stamped")
        XCTAssertNil(try completed(try XCTUnwrap(revB)), "B's erasure was stamped done by a truncation that came before it")

        reader.release()
        XCTAssertTrue(try b.finishErasure())
        XCTAssertNotNil(try completed(try XCTUnwrap(revB)))
    }

    /// Another process mid-read: its snapshot keeps the write-ahead log from being truncated.
    private struct PinnedLog {
        var db: OpaquePointer?
        mutating func release() {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    private static func pinLog(_ path: String) throws -> PinnedLog {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw StoreError.sqlite("can't pin") }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_exec(db, "SELECT COUNT(*) FROM capture_event", nil, nil, nil)
        return PinnedLog(db: db)
    }
}
