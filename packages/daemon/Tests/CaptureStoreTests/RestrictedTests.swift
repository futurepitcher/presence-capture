import Foundation
import SQLite3
import XCTest
@testable import CaptureStore

/// A reader's store (ADR 0008): it reads through grants and appends to the egress log, and SQLite
/// refuses every other write.
final class RestrictedTests: XCTestCase {
    func testAReaderReadsAndIsLoggedButWritesNothingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let key = Seal.newKey()
        let writer = try CaptureStore(path: path, masterKey: key)
        let id = try writer.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "readable"))
        let grant = try writer.issueGrant(NewGrant(clientId: "editor", expiresAt: Date().addingTimeInterval(3600)))

        let reader = try CaptureStore(readerPath: path, masterKey: key)
        XCTAssertEqual(try reader.read(grantId: grant, ReadRequest(tool: "recent")).count, 1)
        XCTAssertEqual(try reader.read(grantId: grant, ReadRequest(tool: "recent")).count, 1, "a second egress record (AUTOINCREMENT) was refused")

        XCTAssertThrowsError(try reader.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "planted")))
        XCTAssertThrowsError(try reader.revoke(scopeKind: "capture", scopeValue: id))
        XCTAssertThrowsError(try reader.issueGrant(NewGrant(clientId: "itself", expiresAt: Date().addingTimeInterval(3600))))
        XCTAssertThrowsError(try reader.revokeGrant(grant))
        XCTAssertThrowsError(try reader.addProjectionEntry(projection: "x", captureId: id, entryRef: "y"))
        XCTAssertEqual(try writer.contentText(id), "readable", "the reader changed what it may only read")
    }

    func testAReaderNeverCreatesOrMigratesAStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing/store.sqlite").path
        XCTAssertThrowsError(try CaptureStore(readerPath: missing, masterKey: Seal.newKey()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing), "a reader created a store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "a reader created a directory")

        // A store an older app made: one migration short of this version.
        let path = dir.appendingPathComponent("old.sqlite").path
        let key = Seal.newKey()
        _ = try CaptureStore(path: path, masterKey: key)
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, "DELETE FROM schema_migration WHERE name = '\(Migrations.all.last!.name)'", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertThrowsError(try CaptureStore(readerPath: path, masterKey: key)) { error in
            XCTAssertTrue("\(error)".contains("isn't migrated"), "\(error)")
        }
        sqlite3_open(path, &db)
        var count: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM schema_migration", -1, &count, nil)
        sqlite3_step(count)
        XCTAssertEqual(Int(sqlite3_column_int(count, 0)), Migrations.all.count - 1, "the reader migrated the store")
        sqlite3_finalize(count)
        sqlite3_close(db)
    }
}
