import Foundation
import XCTest
@testable import CaptureStore

/// What `pcap` and the menu show of the store: grants, what agents were given, and its checks.
final class AdminTests: XCTestCase {
    private var dir: URL!
    private var key = Seal.newKey()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() throws -> CaptureStore {
        try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: key)
    }

    func testGrantsAreListedNewestFirstAndRevokedOnce() throws {
        let store = try store()
        let first = try store.issueGrant(NewGrant(clientId: "claude-code", expiresAt: Date().addingTimeInterval(3600)))
        Thread.sleep(forTimeInterval: 0.01)
        var narrow = NewGrant(clientId: "cursor", expiresAt: Date().addingTimeInterval(-1))
        narrow.captureTypes = ["screen_text"]
        let expired = try store.issueGrant(narrow)

        let grants = try store.grants()
        XCTAssertEqual(grants.map(\.grantId), [expired, first])
        XCTAssertEqual(grants[0].captureTypes, ["screen_text"])
        XCTAssertEqual(grants[1].privacyLevels, ["standard"])
        XCTAssertFalse(grants[0].isActive(), "an expired grant was shown as active")
        XCTAssertTrue(grants[1].isActive())

        XCTAssertTrue(try store.revokeGrant(first))
        XCTAssertFalse(try store.revokeGrant(first), "a grant was revoked twice")
        XCTAssertFalse(try store.revokeGrant("grn_none"), "a grant that doesn't exist was reported revoked")
        XCTAssertNotNil(try store.grants().first { $0.grantId == first }?.revokedAt)
    }

    func testEgressIsCountedByDayClientToolAndTypeNeverContent() throws {
        let store = try store()
        _ = try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "secret on screen"))
        _ = try store.append(NewCapture(capturedAt: Date(), captureType: "audio_transcript", source: "ambient_audio", contentText: "secret said"))
        let code = try store.issueGrant(NewGrant(clientId: "claude-code", expiresAt: Date().addingTimeInterval(3600)))
        let cursor = try store.issueGrant(NewGrant(clientId: "cursor", expiresAt: Date().addingTimeInterval(3600)))
        _ = try store.read(grantId: code, ReadRequest(tool: "recent"))
        _ = try store.read(grantId: code, ReadRequest(tool: "recent", limit: 1))
        _ = try store.read(grantId: cursor, ReadRequest(tool: "search", query: "secret"))

        let utc = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
        let lines = try store.egress(since: Date().addingTimeInterval(-60), calendar: utc)
        XCTAssertEqual(lines.map { "\($0.clientId) \($0.tool)" }, ["claude-code recent", "cursor search"])
        XCTAssertEqual(lines[0].reads, 2)
        XCTAssertEqual(lines[0].rows, 3)
        XCTAssertEqual(lines[0].types.values.reduce(0, +), 3)
        XCTAssertEqual(lines[1].types, ["screen_text": 1, "audio_transcript": 1])
        XCTAssertFalse("\(lines)".contains("secret"), "the egress summary carried content")
        XCTAssertTrue(try store.egress(since: Date().addingTimeInterval(60)).isEmpty)
    }

    func testTheEgressChainVerifiesAndATamperedRecordBreaksIt() throws {
        let store = try store()
        _ = try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "a"))
        let grant = try store.issueGrant(NewGrant(clientId: "agent", expiresAt: Date().addingTimeInterval(3600)))
        for _ in 0..<3 { _ = try store.read(grantId: grant, ReadRequest(tool: "recent")) }
        XCTAssertEqual(try store.verifyEgressChain(), ChainCheck(ok: true, records: 3, brokenAt: nil, reason: nil))

        // As someone with the file could: past the append-only trigger, a record's count lowered.
        try store.exec("DROP TRIGGER egress_no_update")
        try store.exec("UPDATE egress_record SET row_count = 0 WHERE egress_id = 2")
        XCTAssertEqual(try store.verifyEgressChain(), ChainCheck(ok: false, records: 3, brokenAt: 2, reason: "record_hash"))
        XCTAssertEqual(try store.quickCheck(), "ok")
    }

    func testAKeyFileIsRawBytesOrHexAndNothingElse() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data((0..<32).map { UInt8($0) })
        let raw = dir.appendingPathComponent("raw.key"), hex = dir.appendingPathComponent("hex.key")
        try bytes.write(to: raw)
        try Data((bytes.map { String(format: "%02x", $0) }.joined() + "\n").utf8).write(to: hex)
        XCTAssertEqual(try MasterKeyItem.load(keyFile: raw.path, bundleIdentifier: nil), bytes)
        XCTAssertEqual(try MasterKeyItem.load(keyFile: hex.path, bundleIdentifier: nil), bytes)

        let signed = dir.appendingPathComponent("signed.key")
        try Data(("+f" + String(repeating: "0", count: 62)).utf8).write(to: signed)
        XCTAssertThrowsError(try MasterKeyItem.load(keyFile: signed.path, bundleIdentifier: nil), "a sign was read as a hex digit")
        let fullwidth = dir.appendingPathComponent("fullwidth.key")
        try Data(String(repeating: "Ａ", count: 64).utf8).write(to: fullwidth)
        XCTAssertThrowsError(try MasterKeyItem.load(keyFile: fullwidth.path, bundleIdentifier: nil), "fullwidth digits were read, or crashed")
        let upper = dir.appendingPathComponent("upper.key")
        try Data(bytes.map { String(format: "%02X", $0) }.joined().utf8).write(to: upper)
        XCTAssertEqual(try MasterKeyItem.load(keyFile: upper.path, bundleIdentifier: nil), bytes)
        XCTAssertThrowsError(try MasterKeyItem.load(keyFile: dir.appendingPathComponent("none").path, bundleIdentifier: nil))
    }
}
