@testable import CaptureCore
import Foundation
import XCTest

/// WhatsApp Desktop's database, read read-only (docs/sources/whatsapp.md), against an invented one.
final class WhatsAppTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testEveryChatIsReadBothSidesInTheOrderWritten() throws {
        let wa = try WhatsAppFixture()
        let now = Date()
        try wa.add(chat: WhatsAppFixture.alex.pk, mine: false, sent: now, text: "lunch tomorrow?")
        try wa.add(chat: WhatsAppFixture.alex.pk, mine: true, sent: now, text: "yes, noon")
        try wa.add(chat: WhatsAppFixture.team.pk, mine: false, sent: now, text: "draft is up")
        try wa.add(chat: WhatsAppFixture.sam.pk, mine: false, sent: now, text: nil)  // a photo: no text
        let messages = try WhatsAppDatabase(path: wa.path).messages(since: now.addingTimeInterval(-60), after: 0)
        XCTAssertEqual(messages.map(\.text), ["lunch tomorrow?", "yes, noon", "draft is up"])
        XCTAssertEqual(messages.map(\.mine), [false, true, false])
        XCTAssertEqual(messages.map(\.chatName), ["Alex", "Alex", "Project Team"])
        XCTAssertEqual(messages.map(\.group), [false, false, true])
        XCTAssertEqual(messages[0].sent.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testOnlyWhatsSentSinceAndWrittenAfterIsRead() throws {
        let wa = try WhatsAppFixture()
        let now = Date()
        try wa.add(chat: 1, mine: false, sent: now.addingTimeInterval(-40 * day), text: "old")
        let middle = try wa.add(chat: 1, mine: false, sent: now.addingTimeInterval(-10 * day), text: "recent")
        try wa.add(chat: 1, mine: true, sent: now, text: "now")
        let db = try WhatsAppDatabase(path: wa.path)
        XCTAssertEqual(try db.messages(since: now.addingTimeInterval(-30 * day), after: 0).map(\.text), ["recent", "now"])
        XCTAssertEqual(try db.messages(since: .distantPast, after: middle).map(\.text), ["now"])
        XCTAssertEqual(try db.messages(since: .distantPast, after: 0, onlyMine: true).map(\.text), ["now"])
        XCTAssertEqual(try db.lastRow(), 3)
    }

    func testEachMessageBecomesTheObservationThePluginWrites() throws {
        let wa = try WhatsAppFixture()
        let sent = Date(timeIntervalSince1970: 1_790_000_000.25)
        try wa.add(chat: WhatsAppFixture.alex.pk, mine: false, sent: sent, text: "see you there", stanza: "3EB0ABC")
        try wa.add(chat: WhatsAppFixture.alex.pk, mine: true, sent: sent, text: "great")
        try wa.add(chat: WhatsAppFixture.team.pk, mine: false, sent: sent, text: "agenda attached")
        let observed = try WhatsAppDatabase(path: wa.path).messages(since: .distantPast, after: 0).map(WhatsAppDatabase.observation)
        XCTAssertEqual(observed[0]["at"] as? String, "2026-09-21T14:13:20.250Z")
        XCTAssertEqual(observed[0]["kind"] as? String, "screen")
        XCTAssertEqual(observed[0]["app"] as? String, "WhatsApp")
        XCTAssertEqual(observed[0]["bundle"] as? String, "net.whatsapp.WhatsApp.chat-1")
        XCTAssertEqual(observed[0]["window"] as? String, "WhatsApp: Alex")
        XCTAssertEqual(observed[0]["dedupe"] as? String, "wa:3EB0ABC")
        XCTAssertEqual(observed.map { $0["text"] as? String }, ["[Alex] Alex: see you there", "[Alex] Me: great", "[Project Team] Member: agenda attached"])
        // A group member is never named.
        XCTAssertFalse((observed[2]["text"] as? String ?? "").contains("15550"))
    }

    func testAChatWithoutItsNameIsCalledByItsNumberHere() throws {
        let wa = try WhatsAppFixture(names: false)
        try wa.add(chat: 2, mine: false, sent: Date(), text: "hi")
        let db = try WhatsAppDatabase(path: wa.path)
        XCTAssertEqual(try db.messages(since: .distantPast, after: 0).first?.chatName, "Chat 2")
        XCTAssertEqual(try db.chats().map(\.name), ["Chat 2", "Chat 1", "Chat 3"])
    }

    func testChatsAreListedBusiestFirst() throws {
        let wa = try WhatsAppFixture()
        for _ in 0..<3 { try wa.add(chat: 3, mine: false, sent: Date(), text: "x") }
        try wa.add(chat: 2, mine: false, sent: Date(), text: "y")
        let chats = try WhatsAppDatabase(path: wa.path).chats()
        XCTAssertEqual(chats.map(\.name), ["Project Team", "Sam", "Alex"])
        XCTAssertEqual(chats.map(\.messages), [3, 1, 0])
        XCTAssertEqual(chats[0].id, WhatsAppFixture.team.jid)
    }

    func testAChatIsExcludedByItsWholeNameOrItsIdInAnyCase() throws {
        let wa = try WhatsAppFixture()
        try wa.add(chat: 3, mine: false, sent: Date(), text: "x")
        try wa.add(chat: 1, mine: false, sent: Date(), text: "y")
        let messages = try WhatsAppDatabase(path: wa.path).messages(since: .distantPast, after: 0)
        XCTAssertTrue(WhatsAppDatabase.isExcluded(messages[0], by: ["project team"]))
        XCTAssertTrue(WhatsAppDatabase.isExcluded(messages[0], by: [WhatsAppFixture.team.jid.uppercased()]))
        XCTAssertFalse(WhatsAppDatabase.isExcluded(messages[0], by: ["project"]), "part of a name excluded the chat")
        XCTAssertFalse(WhatsAppDatabase.isExcluded(messages[1], by: ["project team"]))
    }

    func testReadingNeverChangesWhatsAppsFiles() throws {
        let wa = try WhatsAppFixture()
        for index in 0..<20 { try wa.add(chat: 1 + index % 3, mine: index % 2 == 0, sent: Date(), text: "message \(index)") }
        let before = wa.bytes()
        for _ in 0..<3 {
            let db = try WhatsAppDatabase(path: wa.path)
            _ = try db.messages(since: .distantPast, after: 0)
            _ = try db.chats()
            _ = try db.lastRow()
        }
        XCTAssertEqual(wa.bytes(), before, "reading changed WhatsApp's database")
        // And a message WhatsApp writes meanwhile is read next time.
        try wa.add(chat: 1, mine: false, sent: Date(), text: "one more")
        XCTAssertEqual(try WhatsAppDatabase(path: wa.path).messages(since: .distantPast, after: 20).map(\.text), ["one more"])
    }

    func testItReadsWhileWhatsAppIsClosedWithoutLeavingFilesBehind() throws {
        let wa = try WhatsAppFixture()
        try wa.add(chat: 1, mine: false, sent: Date(), text: "before quitting")
        wa.close()
        let folder = { Set((try? FileManager.default.contentsOfDirectory(atPath: wa.dir.path)) ?? []) }
        let (files, before) = (folder(), wa.bytes())
        XCTAssertEqual(try WhatsAppDatabase(path: wa.path).messages(since: .distantPast, after: 0).map(\.text), ["before quitting"])
        XCTAssertEqual(folder(), files, "reading left files in WhatsApp's folder")
        XCTAssertEqual(wa.bytes(), before)
    }

    func testADatabaseOfAnotherShapeIsRefusedNotGuessedAt() throws {
        let wa = try WhatsAppFixture(messageColumns: "ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP, ZBODY VARCHAR, ZSTANZAID VARCHAR")
        XCTAssertThrowsError(try WhatsAppDatabase(path: wa.path)) { error in
            guard case WhatsAppDatabase.ReadError.unknownSchema(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("ZTEXT"))
        }
    }

    func testNoDatabaseOrNotADatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try WhatsAppDatabase(path: dir.appendingPathComponent("none.sqlite").path)) {
            XCTAssertEqual($0 as? WhatsAppDatabase.ReadError, .missing)
        }
        let junk = dir.appendingPathComponent("junk.sqlite")
        try Data(repeating: 7, count: 4096).write(to: junk)
        XCTAssertThrowsError(try WhatsAppDatabase(path: junk.path)) {
            guard case WhatsAppDatabase.ReadError.unreadable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: junk), Data(repeating: 7, count: 4096))
    }
}
