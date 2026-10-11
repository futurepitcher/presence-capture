import Foundation
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
        let id = try writer.append(NewCapture(captureType: "screen_text", source: "screen", contentText: "readable"))
        let grant = try writer.issueGrant(NewGrant(clientId: "editor", expiresAt: Date().addingTimeInterval(3600)))

        let reader = try CaptureStore(path: path, masterKey: key)
        reader.restrictToReading()
        XCTAssertEqual(try reader.read(grantId: grant, ReadRequest(tool: "recent")).count, 1)
        XCTAssertEqual(try reader.read(grantId: grant, ReadRequest(tool: "recent")).count, 1, "a second egress record (AUTOINCREMENT) was refused")

        XCTAssertThrowsError(try reader.append(NewCapture(captureType: "screen_text", source: "screen", contentText: "planted")))
        XCTAssertThrowsError(try reader.revoke(scopeKind: "capture", scopeValue: id))
        XCTAssertThrowsError(try reader.issueGrant(NewGrant(clientId: "itself", expiresAt: Date().addingTimeInterval(3600))))
        XCTAssertThrowsError(try reader.revokeGrant(grant))
        XCTAssertThrowsError(try reader.addProjectionEntry(projection: "x", captureId: id, entryRef: "y"))
        XCTAssertEqual(try writer.contentText(id), "readable", "the reader changed what it may only read")
    }
}
