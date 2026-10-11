import CryptoKit
import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible, Equatable {
    /// The schema refused a write: an unknown privacy level, a duplicate dedupe key, a write to an
    /// append-only table.
    case constraint(String)
    /// The master key doesn't open this store.
    case wrongKey
    case sealing
    case sqlite(String)

    public var description: String {
        switch self {
        case .constraint(let message): return "constraint: \(message)"
        case .wrongKey: return "masterKey does not open this store"
        case .sealing: return "sealing failed"
        case .sqlite(let message): return "capture store: \(message)"
        }
    }
}

/// A capture to append. Its text and payload are sealed before anything is written.
public struct NewCapture: Sendable {
    public var captureId: String?
    public var capturedAt: Date?
    public var captureType: String
    public var source: String
    public var sourceApp: String?
    public var sourceUrl: String?
    public var privacyLevel: String
    public var classification: String?
    public var contentText: String?
    public var payload: (bytes: Data, mediaType: String)?
    public var extraction: String?
    public var derivedFrom: String?
    public var dedupeKey: String?

    public init(
        captureId: String? = nil, capturedAt: Date? = nil, captureType: String, source: String, sourceApp: String? = nil,
        sourceUrl: String? = nil, privacyLevel: String = "standard", classification: String? = nil, contentText: String? = nil,
        payload: (bytes: Data, mediaType: String)? = nil, extraction: String? = nil, derivedFrom: String? = nil, dedupeKey: String? = nil
    ) {
        (self.captureId, self.capturedAt, self.captureType, self.source, self.sourceApp, self.sourceUrl) =
            (captureId, capturedAt, captureType, source, sourceApp, sourceUrl)
        (self.privacyLevel, self.classification, self.contentText, self.payload, self.extraction, self.derivedFrom, self.dedupeKey) =
            (privacyLevel, classification, contentText, payload, extraction, derivedFrom, dedupeKey)
    }
}

public struct Revocation: Sendable, Equatable {
    public let revocationId: String
    public let revokedCaptureIds: [String]
    /// False when a reader in another process held the write-ahead log, so the revoked bytes may
    /// still be in it: the erasure isn't done until `finishErasure()` says so.
    public let erasedOnDisk: Bool
}

/// The capture store SCHEMA.md defines, in one SQLite file. The event log records that something
/// was captured; what was captured is sealed per capture, and revocation erases it (ADR 0002).
/// Retention is a scheduled revocation (ADR 0003). One connection, used one call at a time.
public final class CaptureStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let masterKey: SymmetricKey
    /// Keys dedupe values, so a dedupe_key, which outlives a revocation in the append-only log,
    /// can't be matched to what it named without the master key.
    private let dedupeSecret: SymmetricKey
    private let lock = NSLock()
    private var erasurePending = false

    public static let epoch = "0000-01-01T00:00:00.000Z"

    /// Opens (creating when missing) the store at `path`, sealed under `masterKey`, which is never
    /// written down. Refuses a key that isn't this store's.
    public init(path: String, masterKey: SymmetricKey) throws {
        guard masterKey.bitCount == 256 else { throw StoreError.sqlite("masterKey must be 32 bytes") }
        self.masterKey = masterKey
        dedupeSecret = HKDF<SHA256>.deriveKey(inputKeyMaterial: masterKey, info: Data("presence-capture dedupe".utf8), outputByteCount: 32)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw StoreError.sqlite("can't open the store") }
        try exec("PRAGMA foreign_keys = ON")
        // Deleted content is overwritten, not left on a free page (R11).
        try exec("PRAGMA secure_delete = ON")
        try exec("PRAGMA journal_mode = WAL")
        try migrate()
        if let probe = try rows("SELECT capture_id, wrapped_key FROM capture_key LIMIT 1").first {
            do {
                _ = try Seal.open(probe.data(1), key: masterKey, aad: "key:\(probe.text(0))")
            } catch {
                sqlite3_close(db)
                db = nil
                throw StoreError.wrongKey
            }
        }
    }

    deinit { sqlite3_close(db) }

    public func close() {
        lock.withLock {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: Writes

    /// Appends a capture: event, key, sealed text and sealed payload in one transaction, so a
    /// capture never exists half-sealed. The payload hash is over the sealed bytes.
    @discardableResult
    public func append(_ capture: NewCapture) throws -> String {
        try lock.withLock {
            let captureId = capture.captureId ?? "cap_\(UUID().uuidString.lowercased())"
            let dataKey = Seal.newKey()
            let createdAt = Self.iso(Date())
            try transaction {
                var payloadHash: String?
                if let payload = capture.payload {
                    let sealed = try Seal.seal(payload.bytes, key: dataKey, aad: "payload:\(captureId)")
                    let hash = SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined()
                    payloadHash = hash
                    try run("INSERT INTO capture_payload (payload_hash, byte_count, media_type, storage_uri, created_at) VALUES (?, ?, ?, ?, ?)",
                            hash, sealed.count, payload.mediaType, "payload_blob:\(hash)", createdAt)
                    try run("INSERT INTO payload_blob (payload_hash, sealed) VALUES (?, ?)", hash, sealed)
                }
                try run("""
                    INSERT INTO capture_event (
                      capture_id, sequence, captured_at, capture_type, source, source_app, source_url,
                      privacy_level, classification, payload_hash, extraction, derived_from, dedupe_key
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    captureId, try nextSequence(), capture.capturedAt.map(Self.iso) ?? createdAt, capture.captureType, capture.source,
                    capture.sourceApp, capture.sourceUrl, capture.privacyLevel, capture.classification, payloadHash,
                    capture.extraction, capture.derivedFrom, capture.dedupeKey)
                try run("INSERT INTO capture_key (capture_id, wrapped_key, created_at) VALUES (?, ?, ?)",
                        captureId, try Seal.seal(Seal.bytes(dataKey), key: masterKey, aad: "key:\(captureId)"), createdAt)
                if let text = capture.contentText {
                    try run("INSERT INTO capture_content (capture_id, text_sealed, created_at) VALUES (?, ?, ?)",
                            captureId, try Seal.seal(Data(text.utf8), key: dataKey, aad: "text:\(captureId)"), createdAt)
                }
            }
            return captureId
        }
    }

    public func registerProjection(name: String, kind: String) throws {
        try lock.withLock {
            try run("INSERT INTO projection (projection_name, kind, created_at) VALUES (?, ?, ?) ON CONFLICT (projection_name) DO NOTHING",
                    name, kind, Self.iso(Date()))
        }
    }

    /// Records that a projection holds something derived from a capture, so revocation knows what
    /// to prune (R3). With `output` (a kind and its JSON), the store keeps what was derived, sealed
    /// under the capture's own data key (ADR 0007): revoking the capture deletes it and destroys
    /// the key that sealed it.
    public func addProjectionEntry(projection: String, captureId: String, entryRef: String, output: (kind: String, json: Data)? = nil) throws {
        try lock.withLock {
            var sealed: Data?
            if let output {
                guard let wrapped = try rows("SELECT wrapped_key FROM capture_key WHERE capture_id = ?", captureId).first?.data(0) else {
                    throw StoreError.constraint("no output for a capture that is revoked or unknown")
                }
                sealed = try Seal.seal(output.json, key: try dataKey(captureId, wrapped: wrapped), aad: "projection:\(projection):\(captureId):\(entryRef)")
            }
            try run("INSERT INTO projection_entry (projection_name, capture_id, entry_ref, created_at, output_kind, output_sealed) VALUES (?, ?, ?, ?, ?, ?)",
                    projection, captureId, entryRef, Self.iso(Date()), output?.kind, sealed)
        }
    }

    /// The dedupe_key for a value a sensor marks as already seen: HMAC-SHA256 under a key derived
    /// from the master key, over "<source>\u{1F}<value>", as the reference derives it. The store
    /// refuses the same one twice, even after the first is revoked.
    public func dedupeKey(source: String, value: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("\(source)\u{1F}\(value)".utf8), using: dedupeSecret)
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reads of a capture's own content

    /// A capture's text, unsealed; nil when it has none or it was erased.
    public func contentText(_ captureId: String) throws -> String? {
        try lock.withLock {
            guard let row = try rows("""
                SELECT k.wrapped_key, c.text_sealed FROM capture_content c
                JOIN capture_key k ON k.capture_id = c.capture_id WHERE c.capture_id = ?
                """, captureId).first else { return nil }
            let key = try dataKey(captureId, wrapped: row.data(0))
            return String(decoding: try Seal.open(row.data(1), key: key, aad: "text:\(captureId)"), as: UTF8.self)
        }
    }

    /// A capture's payload bytes, unsealed; nil when it has none or they were erased.
    public func payloadBytes(_ captureId: String) throws -> Data? {
        try lock.withLock {
            guard let row = try rows("""
                SELECT k.wrapped_key, b.sealed FROM capture_event e
                JOIN payload_blob b ON b.payload_hash = e.payload_hash
                JOIN capture_key k ON k.capture_id = e.capture_id WHERE e.capture_id = ?
                """, captureId).first else { return nil }
            let key = try dataKey(captureId, wrapped: row.data(0))
            return try Seal.open(row.data(1), key: key, aad: "payload:\(captureId)")
        }
    }

    private func dataKey(_ captureId: String, wrapped: Data) throws -> SymmetricKey {
        SymmetricKey(data: try Seal.open(wrapped, key: masterKey, aad: "key:\(captureId)"))
    }

    // MARK: Revocation and retention

    /// Revokes what the scope names and everything derived from it (R10). In one transaction:
    /// the revocation event, the revoked set, every projection pruned with a receipt (R3), and the
    /// content erased (keys, sealed text, sealed payloads) with an erasure receipt (R11). Then the
    /// write-ahead log, which still holds the frames that wrote the content, is folded in and
    /// truncated.
    @discardableResult
    public func revoke(scopeKind: String, scopeValue: String, reason: String? = nil) throws -> Revocation {
        try lock.withLock {
            let revocationId = "rev_\(UUID().uuidString.lowercased())"
            let revokedAt = Self.iso(Date())
            let affected = try resolve(scopeKind: scopeKind, scopeValue: scopeValue)
            let ids = affected.map(\.id)
            let list = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try transaction {
                try run("INSERT INTO revocation (revocation_id, sequence, revoked_at, scope_kind, scope_value, reason) VALUES (?, ?, ?, ?, ?, ?)",
                        revocationId, try nextSequence(), revokedAt, scopeKind, scopeValue, reason)
                for (id, cascaded) in affected {
                    try run("INSERT INTO revoked_capture (capture_id, revocation_id, revoked_at, cascaded) VALUES (?, ?, ?, ?) ON CONFLICT (capture_id) DO NOTHING",
                            id, revocationId, revokedAt, cascaded ? 1 : 0)
                }
                for projection in try rows("SELECT projection_name FROM projection").map({ $0.text(0) }) {
                    var removed = 0
                    if !ids.isEmpty {
                        removed = try runCounting("DELETE FROM projection_entry WHERE projection_name = ? AND capture_id IN (\(list))", [projection] + ids)
                    }
                    try run("INSERT INTO projection_revocation (projection_name, revocation_id, applied_at, entries_removed) VALUES (?, ?, ?, ?)",
                            projection, revocationId, Self.iso(Date()), removed)
                }
                var (keys, contents, payloads) = (0, 0, 0)
                if !ids.isEmpty {
                    payloads = try runCounting("""
                        DELETE FROM payload_blob WHERE payload_hash IN (
                          SELECT payload_hash FROM capture_event WHERE capture_id IN (\(list)) AND payload_hash IS NOT NULL)
                        """, ids)
                    contents = try runCounting("DELETE FROM capture_content WHERE capture_id IN (\(list))", ids)
                    keys = try runCounting("DELETE FROM capture_key WHERE capture_id IN (\(list))", ids)
                }
                try run("INSERT INTO erasure_receipt (revocation_id, applied_at, keys_destroyed, contents_erased, payloads_erased) VALUES (?, ?, ?, ?, ?)",
                        revocationId, Self.iso(Date()), keys, contents, payloads)
            }
            return Revocation(revocationId: revocationId, revokedCaptureIds: ids, erasedOnDisk: try truncateLog())
        }
    }

    /// An erasure a reader held up and that isn't finished yet.
    public var isErasurePending: Bool { lock.withLock { erasurePending } }

    /// Finishes an erasure a reader held up: true once nothing revoked is left in the log.
    public func finishErasure() throws -> Bool {
        try lock.withLock { erasurePending ? try truncateLog(attempts: 1) : true }
    }

    /// The deleted pages, zeroed by secure_delete, are still preceded in the write-ahead log by
    /// the frames that wrote the content: the log is folded in and truncated, so they're gone too.
    /// A reader in another process holding a snapshot blocks that, and SQLite says so only in the
    /// result row (busy = 1), never as an error. Retried for about a second; true once truncated.
    private func truncateLog(attempts: Int = 20) throws -> Bool {
        for attempt in 0..<attempts {
            if try rows("PRAGMA wal_checkpoint(TRUNCATE)").first?.int(0) == 0 {
                erasurePending = false
                return true
            }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.05) }
        }
        erasurePending = true
        return false
    }

    /// Everything captured `days` or more before `now`, revoked with reason "retention" (ADR 0003).
    /// Nil, and nothing written, when nothing is that old.
    @discardableResult
    public func retain(days: Double, now: Date = Date()) throws -> Revocation? {
        guard days > 0 else { throw StoreError.sqlite("retention days must be positive") }
        let cutoff = Self.iso(now.addingTimeInterval(-days * 86_400))
        let pending = try lock.withLock {
            try rows("SELECT COUNT(*) FROM capture_event WHERE captured_at <= ? AND capture_id NOT IN (SELECT capture_id FROM revoked_capture)", cutoff)
                .first?.int(0) ?? 0
        }
        guard pending > 0 else { return nil }
        return try revoke(scopeKind: "time_range", scopeValue: "\(Self.epoch)/\(cutoff)", reason: "retention")
    }

    /// The captures a scope names, then everything derived from them, transitively (R10): each
    /// with whether it was reached through the chain.
    private func resolve(scopeKind: String, scopeValue: String) throws -> [(id: String, cascaded: Bool)] {
        let seeds: [String]
        switch scopeKind {
        case "capture":
            seeds = try rows("SELECT capture_id FROM capture_event WHERE capture_id = ?", scopeValue).map { $0.text(0) }
        case "source":
            seeds = try rows("SELECT capture_id FROM capture_event WHERE source = ? OR source_app = ?", scopeValue, scopeValue).map { $0.text(0) }
        case "privacy_level":
            seeds = try rows("SELECT capture_id FROM capture_event WHERE privacy_level = ?", scopeValue).map { $0.text(0) }
        case "time_range":
            // In the form captured_at is kept in, so "...05Z" can't sort after "...05.999Z".
            let bounds = scopeValue.split(separator: "/", maxSplits: 1).map(String.init).compactMap(Self.date).map(Self.iso)
            guard bounds.count == 2 else { throw StoreError.sqlite("time_range is from/to, each an ISO 8601 time") }
            seeds = try rows("SELECT capture_id FROM capture_event WHERE captured_at >= ? AND captured_at <= ?", bounds[0], bounds[1]).map { $0.text(0) }
        default:
            throw StoreError.sqlite("unknown scope kind: \(scopeKind)")
        }
        var all = seeds.map { (id: $0, cascaded: false) }
        var seen = Set(seeds)
        var frontier = seeds
        while !frontier.isEmpty {
            let list = Array(repeating: "?", count: frontier.count).joined(separator: ",")
            let children = try rows("SELECT capture_id FROM capture_event WHERE derived_from IN (\(list))", values: frontier).map { $0.text(0) }
                .filter { seen.insert($0).inserted }
            all += children.map { (id: $0, cascaded: true) }
            frontier = children
        }
        return all
    }

    // MARK: SQLite

    private func migrate() throws {
        try exec("CREATE TABLE IF NOT EXISTS schema_migration (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)")
        let applied = Set(try rows("SELECT name FROM schema_migration").map { $0.text(0) })
        for migration in Migrations.all where !applied.contains(migration.name) {
            try transaction {
                try exec(migration.sql)
                try run("INSERT INTO schema_migration (name, applied_at) VALUES (?, ?)", migration.name, Self.iso(Date()))
            }
        }
    }

    private func nextSequence() throws -> Int {
        let sql = """
            SELECT COALESCE(MAX(s), 0) + 1 FROM (
              SELECT MAX(sequence) AS s FROM capture_event UNION ALL SELECT MAX(sequence) AS s FROM revocation)
            """
        return try rows(sql).first?.int(0) ?? 1
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    /// The last error, as the driver protocol classifies it.
    private func failure() -> StoreError {
        let message = String(cString: sqlite3_errmsg(db))
        return sqlite3_errcode(db) == SQLITE_CONSTRAINT ? .constraint(message) : .sqlite(message)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, position)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let data as Data:
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), Self.transient) }
            default: sqlite3_bind_text(statement, position, "\(value!)", -1, Self.transient)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: Any?...) throws {
        _ = try runCounting(sql, values)
    }

    private func runCounting(_ sql: String, _ values: [Any?]) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return Int(sqlite3_changes(db))
    }

    private func rows(_ sql: String, _ values: Any?...) throws -> [Row] {
        try rows(sql, values: values)
    }

    /// Named apart from the variadic one: an array passed there would bind as a single value.
    private func rows(_ sql: String, values: [Any?]) throws -> [Row] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var out: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: out.append(Row(statement))
            case SQLITE_DONE: return out
            default: throw failure()
            }
        }
    }

    private struct Row {
        private var values: [Any?] = []
        init(_ statement: OpaquePointer?) {
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT: values.append(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    values.append(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column)!, count: count))
                default: values.append(nil)
                }
            }
        }
        func text(_ i: Int) -> String { values[i] as? String ?? "" }
        func int(_ i: Int) -> Int { values[i] as? Int ?? 0 }
        func data(_ i: Int) -> Data { values[i] as? Data ?? Data() }
    }

    // MARK: Time

    /// ISO 8601 with milliseconds, as the reference writes it, so ranges compare as text.
    public static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!))
    }

    public static func date(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
