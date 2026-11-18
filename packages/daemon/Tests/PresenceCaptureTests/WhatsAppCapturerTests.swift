import CaptureCore
@testable import CaptureStore
import CryptoKit
import Foundation
@testable import PresenceCapture
import XCTest

/// WhatsApp, built into the app: off until turned on, then every chat but the excluded, through the
/// gate, from when it was turned on or as far back as history was asked for, and never twice.
final class WhatsAppCapturerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private var dir: URL!
    private var store: CaptureStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private let held = Flag()
    private let chats = Box([])
    private let fragments = Box([])

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        suite = "presence.capture.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func capturer(_ wa: WhatsAppFixture) -> WhatsAppCapturer {
        let (held, chats, fragments) = (self.held, self.chats, self.fragments)
        return WhatsAppCapturer(path: wa.path, store: store, defaults: defaults, held: { held.value }, fragments: { fragments.value },
                                chats: { chats.value }, log: { _ in })
    }

    /// The text of every WhatsApp capture still kept, in the order kept.
    private func kept() throws -> [String] {
        try store.rows("SELECT capture_id FROM capture_event WHERE source = 'whatsapp' ORDER BY sequence").compactMap { try store.contentText($0.text(0)) }
    }

    func testOffUntilTurnedOnAndThenOnlyFromThen() throws {
        let wa = try WhatsAppFixture()
        let whatsApp = capturer(wa)
        try wa.add(chat: 1, mine: false, sent: Date().addingTimeInterval(-60), text: "before consent")
        XCTAssertEqual(whatsApp.pollNow(), .off)
        XCTAssertEqual(try kept(), [])

        whatsApp.turnOn()
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), [], "what was sent before it was turned on was kept without being asked for")
        try wa.add(chat: 1, mine: false, sent: Date(), text: "after consent")
        try wa.add(chat: 3, mine: true, sent: Date(), text: "mine, in the group")
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), ["[Alex] Alex: after consent", "[Project Team] Me: mine, in the group"])
        let apps = try store.rows("SELECT source_app, capture_type FROM capture_event WHERE source = 'whatsapp' ORDER BY sequence")
        XCTAssertEqual(apps.map { $0.text(0) }, ["net.whatsapp.WhatsApp.chat-1", "net.whatsapp.WhatsApp.chat-3"])
        XCTAssertEqual(apps.map { $0.text(1) }, ["screen_text", "screen_text"])

        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept().count, 2, "read twice")
        whatsApp.turnOff()
        try wa.add(chat: 1, mine: false, sent: Date(), text: "after turning off")
        XCTAssertEqual(whatsApp.pollNow(), .off)
        XCTAssertEqual(try kept().count, 2)
    }

    func testHistoryIsBroughtInOnlyAsFarAsAskedAndNeverTwice() throws {
        let wa = try WhatsAppFixture()
        try wa.add(chat: 1, mine: false, sent: Date().addingTimeInterval(-40 * day), text: "forty days ago")
        try wa.add(chat: 2, mine: true, sent: Date().addingTimeInterval(-10 * day), text: "ten days ago")
        try wa.add(chat: 3, mine: false, sent: Date().addingTimeInterval(-5 * day), text: "excluded group")
        chats.value = ["project team"]
        let whatsApp = capturer(wa)
        whatsApp.turnOn(historyDays: 30)
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), ["[Sam] Me: ten days ago"])

        whatsApp.importHistory(days: 90)
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept().sorted(), ["[Alex] Alex: forty days ago", "[Sam] Me: ten days ago"])
        XCTAssertEqual(whatsApp.takeStats().duplicates, 1, "a message already kept wasn't recognised")
    }

    func testHistoryIsNeverMoreThanAYearOrThanRetentionKeeps() {
        XCTAssertEqual(WhatsAppCapturer.historyDays(90, retentionDays: AppDelegate.defaultRetentionDays), 90)
        XCTAssertEqual(WhatsAppCapturer.historyDays(365, retentionDays: AppDelegate.keepIndefinitely), 365)
        XCTAssertEqual(WhatsAppCapturer.historyDays(5_000, retentionDays: AppDelegate.keepIndefinitely), 365)
        XCTAssertEqual(WhatsAppCapturer.historyDays(90, retentionDays: 30), 30)
        XCTAssertEqual(WhatsAppCapturer.historyDays(-1, retentionDays: 30), 0)
        XCTAssertEqual(WhatsAppCapturer.historyChoices.first, 0, "none isn't the first choice")
    }

    func testWhatsWrittenWhileHeldIsPassedOverNotKeptLater() throws {
        let wa = try WhatsAppFixture()
        let whatsApp = capturer(wa)
        whatsApp.turnOn()
        held.value = true
        try wa.add(chat: 1, mine: false, sent: Date(), text: "while paused")
        XCTAssertEqual(whatsApp.pollNow(), .on)
        held.value = false
        XCTAssertEqual(whatsApp.pollNow(), .on)
        try wa.add(chat: 1, mine: false, sent: Date(), text: "after resuming")
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), ["[Alex] Alex: after resuming"])
    }

    func testAListThatCantBeReadHoldsTheReadUntilItCan() throws {
        let wa = try WhatsAppFixture()
        let whatsApp = capturer(wa)
        whatsApp.turnOn()
        try wa.add(chat: 1, mine: false, sent: Date(), text: "hello")
        try wa.add(chat: 2, mine: false, sent: Date(), text: "private")
        chats.value = nil
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), [])
        // Once it can be read, it's read as it is then.
        chats.value = ["sam"]
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), ["[Alex] Alex: hello"])
        // The app's own list drops it too, by app or by window.
        fragments.value = ["whatsapp"]
        try wa.add(chat: 1, mine: false, sent: Date(), text: "dropped at the gate")
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), ["[Alex] Alex: hello"])
    }

    func testAForgottenChatIsGoneAndDoesntComeBack() throws {
        let wa = try WhatsAppFixture()
        let whatsApp = capturer(wa)
        whatsApp.turnOn(historyDays: 30)
        try wa.add(chat: 1, mine: false, sent: Date().addingTimeInterval(-day), text: "keep this")
        try wa.add(chat: 2, mine: false, sent: Date().addingTimeInterval(-day), text: "forget this")
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept().count, 2)
        _ = try store.revoke(scopeKind: "source", scopeValue: WhatsAppDatabase.chatSource(2), reason: "forget whatsapp chat")
        XCTAssertEqual(try kept(), ["[Alex] Alex: keep this"])
        whatsApp.importHistory(days: 90)
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), ["[Alex] Alex: keep this"], "a forgotten chat came back")
    }

    func testAReinstalledWhatsAppIsReadFromItsStart() throws {
        let wa = try WhatsAppFixture()
        let whatsApp = capturer(wa)
        whatsApp.turnOn()
        defaults.set(5_000, forKey: WhatsAppCapturer.afterKey)
        try wa.add(chat: 1, mine: false, sent: Date(), text: "first in a new database")
        XCTAssertEqual(whatsApp.pollNow(), .on)
        XCTAssertEqual(try kept(), ["[Alex] Alex: first in a new database"])
    }

    func testWhatCantBeReadSaysWhy() throws {
        let missing = WhatsAppCapturer(path: dir.appendingPathComponent("none.sqlite").path, store: store, defaults: defaults, held: { false },
                                       fragments: { [] }, chats: { [] }, log: { _ in })
        XCTAssertEqual(missing.pollNow(), .notInstalled)
        missing.turnOn()
        XCTAssertEqual(missing.pollNow(), .notInstalled)

        let junk = dir.appendingPathComponent("junk.sqlite")
        try Data(repeating: 7, count: 4096).write(to: junk)
        let unreadable = WhatsAppCapturer(path: junk.path, store: store, defaults: defaults, held: { false }, fragments: { [] }, chats: { [] }, log: { _ in })
        XCTAssertEqual(unreadable.pollNow(), .needsAccess)

        let other = try WhatsAppFixture(messageColumns: "ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP, ZBODY VARCHAR, ZSTANZAID VARCHAR")
        XCTAssertEqual(capturer(other).pollNow(), .unknownSchema)
    }
}

/// A value read and written from any thread, for the lists a test changes.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String]?
    init(_ value: [String]?) { stored = value }
    var value: [String]? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
