import Foundation
import SQLite3

/// A WhatsApp Desktop database made up for tests: the tables and columns the reader knows, in WAL
/// mode like WhatsApp's own, written through a connection of its own while the reader reads. Every
/// chat, number and message in it is invented. (A copy lives in PresenceCaptureTests: keep them alike.)
final class WhatsAppFixture {
    static let alex = (pk: 1, jid: "15550100001@s.whatsapp.net", name: "Alex")
    static let sam = (pk: 2, jid: "15550100002@s.whatsapp.net", name: "Sam")
    static let team = (pk: 3, jid: "120363000000000001@g.us", name: "Project Team")

    let dir: URL
    let path: String
    private var db: OpaquePointer?
    private var next = 1

    /// `names`: whether chats carry the name WhatsApp shows. `messageColumns`: the message table's
    /// columns, for a database shaped otherwise.
    init(names: Bool = true, messageColumns: String = "ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP, ZTEXT VARCHAR, ZSTANZAID VARCHAR") throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("ChatStorage.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try exec("PRAGMA journal_mode = WAL")
        try exec("CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR\(names ? ", ZPARTNERNAME VARCHAR" : ""))")
        try exec("CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, \(messageColumns))")
        for chat in [Self.alex, Self.sam, Self.team] {
            try exec("INSERT INTO ZWACHATSESSION VALUES (\(chat.pk), '\(chat.jid)'\(names ? ", '\(chat.name)'" : ""))")
        }
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A message, as WhatsApp writes one: its row number is returned.
    @discardableResult
    func add(chat: Int, mine: Bool, sent: Date, text: String?, stanza: String? = nil) throws -> Int {
        let pk = next
        next += 1
        let quoted = { (value: String?) in value.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL" }
        try exec("""
            INSERT INTO ZWAMESSAGE (Z_PK, ZCHATSESSION, ZISFROMME, ZMESSAGEDATE, ZTEXT, ZSTANZAID)
            VALUES (\(pk), \(chat), \(mine ? 1 : 0), \(sent.timeIntervalSince1970 - 978_307_200), \(quoted(text)), \(quoted(stanza ?? "STANZA\(pk)")))
            """)
        return pk
    }

    /// WhatsApp quits: its connection closes, and its write-ahead log is folded in and removed.
    func close() {
        sqlite3_close(db)
        db = nil
    }

    /// Every byte of the database and its write-ahead log, to tell whether anything changed them.
    func bytes() -> Data {
        ["", "-wal"].reduce(into: Data()) { all, suffix in all.append((try? Data(contentsOf: URL(fileURLWithPath: path + suffix))) ?? Data()) }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}
