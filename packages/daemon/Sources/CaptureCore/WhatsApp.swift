import Foundation
import SQLite3

/// WhatsApp Desktop's own message database on this Mac, read read-only (docs/sources/whatsapp.md):
/// the text of every chat, as the app's WhatsApp capture notes it. The same reading, and the same
/// observations, as packages/plugins/whatsapp/sensor.mjs.
///
/// Opened read-only and query-only, a read at a time: nothing here can change WhatsApp's data, and
/// it never holds the file open between reads. It only knows the columns in `required`, and refuses
/// a database without them rather than guess. No media is read, and nothing talks to WhatsApp.
public final class WhatsAppDatabase {
    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }
    /// Core Data stamps seconds since 2001-01-01T00:00:00Z.
    public static let appleEpoch: TimeInterval = 978_307_200
    /// The columns read. Unverified against every WhatsApp release: any one missing, and it stops.
    public static let required: [(table: String, columns: [String])] = [
        ("ZWAMESSAGE", ["Z_PK", "ZCHATSESSION", "ZISFROMME", "ZMESSAGEDATE", "ZTEXT", "ZSTANZAID"]),
        ("ZWACHATSESSION", ["Z_PK", "ZCONTACTJID"]),
    ]
    /// The chat's name as WhatsApp shows it, read when it's there. Without it a chat is "Chat <n>".
    static let nameColumn = "ZPARTNERNAME"
    /// The furthest back history may be imported.
    public static let historyMaxDays = 365
    public static let bundle = "net.whatsapp.WhatsApp"

    /// Each chat's captures carry this as their app, so one chat can be forgotten alone. The chat's
    /// row number means nothing off this Mac.
    public static func chatSource(_ chat: Int) -> String { "\(bundle).chat-\(chat)" }

    public struct Message: Equatable, Sendable {
        public let pk: Int
        public let chat: Int
        public let chatId: String?
        public let chatName: String
        public let mine: Bool
        public let sent: Date
        public let text: String
        public let stanza: String?
        public var group: Bool { chatId?.hasSuffix("@g.us") ?? false }
    }

    public struct Chat: Equatable, Sendable {
        public let pk: Int
        public let id: String?
        public let name: String
        public let messages: Int
    }

    public enum ReadError: Error, Equatable {
        /// No database where WhatsApp Desktop keeps it (or none this app is allowed to see).
        case missing
        /// There, but not readable: most often, macOS hasn't allowed this app to read it yet.
        case unreadable(String)
        /// Not a database this reader knows.
        case unknownSchema(String)
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String = WhatsAppDatabase.defaultPath) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw ReadError.missing }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            db = nil
            throw ReadError.unreadable(message)
        }
        sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil)
        // The first read: a permission macOS hasn't given shows here.
        if let why = try schemaError() { throw ReadError.unknownSchema(why) }
    }

    deinit { sqlite3_close(db) }

    /// Nil when every column read is there; otherwise what's missing.
    func schemaError() throws -> String? {
        for (table, columns) in Self.required {
            let have = Set(try rows("PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1] as? String : nil })
            if have.isEmpty { return "no table \(table)" }
            let missing = columns.filter { !have.contains($0) }
            if !missing.isEmpty { return "\(table) lacks \(missing.joined(separator: ", "))" }
        }
        return nil
    }

    private func nameSQL() throws -> String {
        let columns = try rows("PRAGMA table_info(ZWACHATSESSION)").compactMap { $0.count > 1 ? $0[1] as? String : nil }
        return columns.contains(Self.nameColumn) ? "s.\(Self.nameColumn)" : "NULL"
    }

    private static func name(_ value: Any?, chat: Int) -> String {
        let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Chat \(chat)" : name
    }

    /// The highest row written: the watermark a read can't be past, unless the database was made
    /// again (WhatsApp reinstalled).
    public func lastRow() throws -> Int {
        try rows("SELECT MAX(Z_PK) FROM ZWAMESSAGE").first?.first.flatMap { $0 as? Int } ?? 0
    }

    /// Every text message sent after `since` and written after row `after`, in the order written,
    /// every chat's: excluding is the caller's, so it moves its watermark past what it skips. The row
    /// is the watermark, not the time, so a message synced to this Mac late isn't missed. A message
    /// with no text (media, a deleted message's tombstone) isn't read.
    public func messages(since: Date, after: Int, onlyMine: Bool = false) throws -> [Message] {
        try rows("""
            SELECT m.Z_PK, m.ZISFROMME, m.ZMESSAGEDATE, m.ZTEXT, m.ZSTANZAID, s.Z_PK, s.ZCONTACTJID, \(try nameSQL())
            FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            WHERE m.ZMESSAGEDATE > ? AND m.Z_PK > ? AND m.ZTEXT IS NOT NULL AND m.ZTEXT <> ''
            \(onlyMine ? "AND m.ZISFROMME = 1" : "")
            ORDER BY m.Z_PK
            """, since.timeIntervalSince1970 - Self.appleEpoch, after).compactMap { r in
            guard let pk = r[0] as? Int, let chat = r[5] as? Int, let text = r[3] as? String, let date = Self.number(r[2]) else { return nil }
            return Message(pk: pk, chat: chat, chatId: r[6] as? String, chatName: Self.name(r[7], chat: chat), mine: (r[1] as? Int ?? 0) != 0,
                           sent: Date(timeIntervalSince1970: date + Self.appleEpoch), text: text, stanza: r[4] as? String)
        }
    }

    /// Every chat, most messages first.
    public func chats() throws -> [Chat] {
        try rows("""
            SELECT s.Z_PK, s.ZCONTACTJID, \(try nameSQL()), COUNT(m.Z_PK)
            FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
            GROUP BY s.Z_PK ORDER BY COUNT(m.Z_PK) DESC, s.Z_PK
            """).compactMap { r in
            guard let pk = r[0] as? Int else { return nil }
            return Chat(pk: pk, id: r[1] as? String, name: Self.name(r[2], chat: pk), messages: r[3] as? Int ?? 0)
        }
    }

    /// Whether a line of the exclude list names this chat: its whole name or its id, in any case.
    public static func isExcluded(_ message: Message, by list: [String]) -> Bool {
        let keys = Set(list.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return keys.contains(message.chatName.lowercased()) || (message.chatId.map { keys.contains($0.lowercased()) } ?? false)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoLock = NSLock()

    /// The observation a message becomes (ADR 0007's `screen`), as the plugin writes it. The chat's
    /// name is in the text, since a screen capture keeps its text and not its window. In a group,
    /// other members are "Member", never named.
    public static func observation(_ m: Message) -> [String: Any] {
        let who = m.mine ? "Me" : m.group ? "Member" : m.chatName
        let at = isoLock.withLock { iso.string(from: m.sent) }
        return [
            "at": at,
            "kind": "screen",
            "app": "WhatsApp",
            "bundle": chatSource(m.chat),
            "window": "WhatsApp: \(m.chatName)",
            "text": "[\(m.chatName)] \(who): \(m.text)",
            // A message's own id: read again, it adds nothing, and once forgotten it never comes back.
            "dedupe": String("wa:\(m.stanza ?? "pk-\(m.pk)")".prefix(200)),
        ]
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        default: return nil
        }
    }

    private func rows(_ sql: String, _ values: Any?...) throws -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let text as String: _ = text.withCString { sqlite3_bind_text(statement, position, $0, Int32(text.utf8.count), Self.transient) }
            default: sqlite3_bind_null(statement, position)
            }
        }
        var out: [[Any?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError.unreadable(String(cString: sqlite3_errmsg(db))) }
            out.append((0..<sqlite3_column_count(statement)).map { column -> Any? in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return Int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
                case SQLITE_TEXT:
                    guard let text = sqlite3_column_text(statement, column) else { return nil }
                    return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
                default: return nil
                }
            })
        }
        return out
    }
}
