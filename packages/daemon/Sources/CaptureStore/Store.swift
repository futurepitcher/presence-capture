import CryptoKit
import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible, Equatable {
    /// The schema refused a write: an unknown privacy level, a duplicate dedupe key, a write to an
    /// append-only table.
    case constraint(String)
    /// The master key doesn't open this store.
    case wrongKey
    /// A read the grant doesn't allow: no grant, a revoked one, an expired one (ADR 0001).
    case denied(String)
    /// A write that would bring back what a revocation forgot: a capture stamped inside a revoked
    /// time range or derived from a revoked capture, or a projection entry for a revoked capture.
    case revoked(String)
    case sealing
    case sqlite(String)

    public var description: String {
        switch self {
        case .constraint(let message): return "constraint: \(message)"
        case .wrongKey: return "masterKey does not open this store"
        case .denied(let message): return "denied: \(message)"
        case .revoked(let message): return "revoked: \(message)"
        case .sealing: return "sealing failed"
        case .sqlite(let message): return "capture store: \(message)"
        }
    }
}

/// A capture to append. Its text and payload are sealed before anything is written.
///
/// `capturedAt` is when it was observed, taken before anything was read, never when it's written:
/// a revocation refuses what's stamped inside the range it forgot, so a screen read or speech
/// transcribed while a range was being forgotten can't arrive after it, stamped later, and be kept.
public struct NewCapture: Sendable {
    public var captureId: String?
    public var capturedAt: Date
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
        captureId: String? = nil, capturedAt: Date, captureType: String, source: String, sourceApp: String? = nil,
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
    /// Why finishing the erasure failed after the revocation was committed, when it did. The
    /// revocation stands; the erasure is pending and is finished later.
    public var erasureError: String?

    public init(revocationId: String, revokedCaptureIds: [String], erasedOnDisk: Bool, erasureError: String? = nil) {
        (self.revocationId, self.revokedCaptureIds, self.erasedOnDisk, self.erasureError) = (revocationId, revokedCaptureIds, erasedOnDisk, erasureError)
    }
}

/// The capture store SCHEMA.md defines, in one SQLite file. The event log records that something
/// was captured; what was captured is sealed per capture, and revocation erases it (ADR 0002).
/// Retention is a scheduled revocation (ADR 0003). One connection, used one call at a time.
public final class CaptureStore: @unchecked Sendable {
    var db: OpaquePointer?
    let masterKey: SymmetricKey
    /// Keys dedupe values, so a dedupe_key, which outlives a revocation in the append-only log,
    /// can't be matched to what it named without the master key.
    private let dedupeSecret: SymmetricKey
    let lock = NSLock()

    public static let epoch = "0000-01-01T00:00:00.000Z"

    /// Where the app keeps its store and log, and where `pcap-mcp` and `pcap` look for them:
    /// PRESENCE_CAPTURE_HOME, or the default.
    public static var home: String { ProcessInfo.processInfo.environment["PRESENCE_CAPTURE_HOME"] ?? defaultHome }

    /// ~/Library/Application Support/Presence Capture: where `pcap-mcp` looks when an agent starts it,
    /// with none of the person's environment.
    public static var defaultHome: String { NSHomeDirectory() + "/Library/Application Support/Presence Capture" }

    /// Opens (creating when missing) the store at `path`, sealed under `masterKey`, which is never
    /// written down. Refuses a key that isn't this store's.
    public init(path: String, masterKey: SymmetricKey) throws {
        guard masterKey.bitCount == 256 else { throw StoreError.sqlite("masterKey must be 32 bytes") }
        self.masterKey = masterKey
        dedupeSecret = HKDF<SHA256>.deriveKey(inputKeyMaterial: masterKey, info: Data("presence-capture dedupe".utf8), outputByteCount: 32)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw StoreError.sqlite("can't open the store") }
        // Another process (a reader, another writer) may hold the write lock for a moment: wait for it.
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA foreign_keys = ON")
        // Deleted content is overwritten, not left on a free page (R11).
        try exec("PRAGMA secure_delete = ON")
        // What a revocation reaches is worked out in a temp table: kept in memory, never in a file
        // outside the store's directory.
        try exec("PRAGMA temp_store = MEMORY")
        try switchToWAL()
        try migrate()
        do {
            try checkKey(writing: true)
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
        // A writer opening the store finishes what an earlier one couldn't: a command-line
        // revocation, say, that exited while a reader held the log.
        if try erasurePending() { _ = try truncateLog(attempts: 1) }
    }

    /// Opens an existing store as a reader (ADR 0008): restricted by SQLite to reads and egress
    /// records before any SQL runs, so opening it can't change it. It never creates, migrates or
    /// sets a persistent option: a store that's missing, or that the app hasn't migrated to this
    /// version, is refused. Migrating is the writer's job.
    public init(readerPath path: String, masterKey: SymmetricKey) throws {
        guard masterKey.bitCount == 256 else { throw StoreError.sqlite("masterKey must be 32 bytes") }
        self.masterKey = masterKey
        dedupeSecret = HKDF<SHA256>.deriveKey(inputKeyMaterial: masterKey, info: Data("presence-capture dedupe".utf8), outputByteCount: 32)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw StoreError.sqlite("no store at that path")
        }
        installReaderAuthorizer()
        sqlite3_busy_timeout(db, 5000)
        let applied = Set((try? rows("SELECT name FROM schema_migration").map { $0.text(0) }) ?? [])
        guard Migrations.all.allSatisfy({ applied.contains($0.name) }) else {
            sqlite3_close(db)
            db = nil
            throw StoreError.sqlite("the store isn't migrated to this version: open it with Presence Capture first")
        }
        do {
            try checkKey(writing: false)
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    static let keyCheck = "presence-capture key check"

    /// Refuses a master key that isn't the store's (migration 009): against the store's own key
    /// check; where there's none yet, against a capture's key, and then a writer writes the check, so
    /// a store with every capture revoked still knows its key. Written with INSERT OR IGNORE and read
    /// back, so of two writers opening it at once, the one whose key differs is refused.
    private func checkKey(writing: Bool) throws {
        func opens(_ sealed: Data, aad: String, expected: String? = nil) -> Bool {
            guard let value = try? Seal.open(sealed, key: masterKey, aad: aad) else { return false }
            return expected.map { Data($0.utf8) == value } ?? true
        }
        var check = try rows("SELECT sealed FROM key_check WHERE id = 1").first?.data(0)
        if check == nil {
            if let probe = try rows("SELECT capture_id, wrapped_key FROM capture_key LIMIT 1").first,
               !opens(probe.data(1), aad: "key:\(probe.text(0))") { throw StoreError.wrongKey }
            guard writing else { return }
            try run("INSERT OR IGNORE INTO key_check (id, sealed, created_at) VALUES (1, ?, ?)",
                    try Seal.seal(Data(Self.keyCheck.utf8), key: masterKey, aad: "key_check"), Self.iso(Date()))
            check = try rows("SELECT sealed FROM key_check WHERE id = 1").first?.data(0)
        }
        guard let check, opens(check, aad: "key_check", expected: Self.keyCheck) else { throw StoreError.wrongKey }
    }

    /// A new store is switched to WAL by whichever writer gets there first, and SQLite tells the
    /// other it's locked at once rather than after its busy timeout: so that one waits here, as
    /// long as the timeout would have.
    private func switchToWAL() throws {
        for waited in stride(from: 0, through: 5000, by: 20) {
            if sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil) == SQLITE_OK { return }
            guard sqlite3_errcode(db) == SQLITE_BUSY, waited < 5000 else { throw failure() }
            Thread.sleep(forTimeInterval: 0.02)
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
        try appendAll([capture])[0]
    }

    /// Appends several captures in one transaction: all of them or none. A later one can name an
    /// earlier one as `derivedFrom` by the `captureId` it was given (`newCaptureId()`), so an audio
    /// segment and its transcript land together, and a duplicate segment (its dedupe key) or a
    /// failed transcript leaves nothing.
    @discardableResult
    public func appendAll(_ captures: [NewCapture]) throws -> [String] {
        try lock.withLock {
            var ids: [String] = []
            // Under the write lock from the start, so no revocation can commit between the check
            // that nothing here was forgotten and the write.
            try transaction(immediate: true) { ids = try captures.map(appendLocked) }
            return ids
        }
    }

    /// An id for a capture not written yet, so another in the same batch can name it.
    public static func newCaptureId() -> String { "cap_\(UUID().uuidString.lowercased())" }

    private func appendLocked(_ capture: NewCapture) throws -> String {
        let captureId = capture.captureId ?? Self.newCaptureId()
        let dataKey = Seal.newKey()
        let createdAt = Self.iso(Date())
        let capturedAt = Self.iso(capture.capturedAt)
        if capture.derivedFrom == captureId { throw StoreError.constraint("a capture cannot be derived from itself") }
        try refuseForgotten(capturedAt: capturedAt, derivedFrom: capture.derivedFrom)
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
            captureId, try nextSequence(), capturedAt, capture.captureType, capture.source,
            capture.sourceApp, capture.sourceUrl, capture.privacyLevel, capture.classification, payloadHash,
            capture.extraction, capture.derivedFrom, capture.dedupeKey)
        try run("INSERT INTO capture_key (capture_id, wrapped_key, created_at) VALUES (?, ?, ?)",
                captureId, try Seal.seal(Seal.bytes(dataKey), key: masterKey, aad: "key:\(captureId)"), createdAt)
        if let text = capture.contentText {
            try run("INSERT INTO capture_content (capture_id, text_sealed, created_at) VALUES (?, ?, ?)",
                    captureId, try Seal.seal(Data(text.utf8), key: dataKey, aad: "text:\(captureId)"), createdAt)
        }
        return captureId
    }

    /// A revocation forgets what it names from then on, too. A capture stamped inside a revoked time
    /// range is refused: speech written after it was said, a screen read while the range was being
    /// forgotten, anything older than retention. So is one derived from a revoked capture. Either
    /// would otherwise arrive after the revocation and be readable.
    private func refuseForgotten(capturedAt: String, derivedFrom: String?) throws {
        // A range kept in canonical form (revoke) compares as text. One a version before migration 008
        // kept as it was given (to the second, say) is read into that form here, so it forgets as much
        // as it did when it was made.
        var forgotten = try !rows("""
            SELECT 1 FROM revocation WHERE scope_kind = 'time_range' AND \(Self.canonicalRangeSQL)
              AND substr(scope_value, 1, 24) <= ? AND substr(scope_value, 26, 24) >= ?
            LIMIT 1
            """, capturedAt, capturedAt).isEmpty
        if !forgotten {
            forgotten = try rows("SELECT scope_value FROM revocation WHERE scope_kind = 'time_range' AND NOT \(Self.canonicalRangeSQL)")
                .contains { row in
                    // One that never parsed never resolved, so it never forgot anything.
                    guard let bounds = try? Self.canonicalRange(row.text(0)).split(separator: "/").map(String.init) else { return false }
                    return bounds[0] <= capturedAt && bounds[1] >= capturedAt
                }
        }
        if forgotten { throw StoreError.revoked("captured_at falls in a revoked time range") }
        if let derivedFrom, try isRevoked(derivedFrom) { throw StoreError.revoked("derived_from names a revoked capture") }
    }

    /// True in SQL when a time_range scope_value is two canonical times, which compare as text.
    static let canonicalRangeSQL = """
        (length(scope_value) = 49 AND substr(scope_value, 25, 1) = '/'
          AND substr(scope_value, 20, 1) = '.' AND substr(scope_value, 24, 1) = 'Z'
          AND substr(scope_value, 45, 1) = '.' AND substr(scope_value, 49, 1) = 'Z')
        """

    func isRevoked(_ captureId: String) throws -> Bool {
        try !rows("SELECT 1 FROM revoked_capture WHERE capture_id = ?", captureId).isEmpty
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
    ///
    /// Under the write lock from the start, so a revocation can't land between the check and the
    /// insert and leave an entry behind for a capture it pruned.
    public func addProjectionEntry(projection: String, captureId: String, entryRef: String, output: (kind: String, json: Data)? = nil) throws {
        try lock.withLock {
            try transaction(immediate: true) {
                try addProjectionEntryLocked(projection: projection, captureId: captureId, entryRef: entryRef, output: output)
            }
        }
    }

    /// A projector's outputs for one capture and its watermark, in one transaction (ADR 0007): a
    /// capture is projected whole or not at all, and the watermark never passes a capture whose
    /// outputs weren't all kept. A capture revoked meanwhile is refused (`StoreError.revoked`).
    public func recordProjection(projection: String, captureId: String, outputs: [(ref: String, kind: String, json: Data)],
                                 consumer: String, sequence: Int) throws {
        try lock.withLock {
            try transaction(immediate: true) {
                for output in outputs {
                    try addProjectionEntryLocked(projection: projection, captureId: captureId, entryRef: output.ref, output: (output.kind, output.json))
                }
                try setWatermarkLocked(consumer: consumer, sequence: sequence)
            }
        }
    }

    /// A consumer's position in the event stream (R4): the last sequence it processed.
    public func watermark(consumer: String) throws -> Int {
        try lock.withLock { try rows("SELECT last_sequence FROM replay_watermark WHERE consumer = ?", consumer).first?.int(0) ?? 0 }
    }

    public func setWatermark(consumer: String, sequence: Int) throws {
        try lock.withLock { try setWatermarkLocked(consumer: consumer, sequence: sequence) }
    }

    private func setWatermarkLocked(consumer: String, sequence: Int) throws {
        try run("""
            INSERT INTO replay_watermark (consumer, last_sequence, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (consumer) DO UPDATE SET last_sequence = excluded.last_sequence, updated_at = excluded.updated_at
            """, consumer, sequence, Self.iso(Date()))
    }

    private func addProjectionEntryLocked(projection: String, captureId: String, entryRef: String, output: (kind: String, json: Data)?) throws {
        if try isRevoked(captureId) { throw StoreError.revoked("no projection entry for a capture that is revoked or unknown") }
        var sealed: Data?
        if let output {
            guard let wrapped = try rows("SELECT wrapped_key FROM capture_key WHERE capture_id = ?", captureId).first?.data(0) else {
                throw StoreError.revoked("no output for a capture that is revoked or unknown")
            }
            sealed = try Seal.seal(output.json, key: try dataKey(captureId, wrapped: wrapped), aad: "projection:\(projection):\(captureId):\(entryRef)")
        }
        // Recording again that an entry exists changes nothing, so an index that failed after
        // recording can retry. An entry with an output is kept once.
        let again = output == nil ? " ON CONFLICT (projection_name, capture_id, entry_ref) DO NOTHING" : ""
        // An output takes the next number in the store's sequence (migration 010), so a reader
        // that follows outputs finds one written after its capture.
        try run("INSERT INTO projection_entry (projection_name, capture_id, entry_ref, created_at, output_kind, output_sealed, output_sequence) VALUES (?, ?, ?, ?, ?, ?, ?)" + again,
                projection, captureId, entryRef, Self.iso(Date()), output?.kind, sealed, output == nil ? nil : try nextSequence())
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

    func dataKey(_ captureId: String, wrapped: Data) throws -> SymmetricKey {
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
            // Kept in canonical form, so later appends compare against it as text (refuseForgotten).
            let value = scopeKind == "time_range" ? try Self.canonicalRange(scopeValue) : scopeValue
            var ids: [String] = []
            // The scope is resolved under the write lock, in the transaction that records it: a capture
            // another writer appends meanwhile is either in the set, or appended after this commits and
            // refused (refuseForgotten).
            try transaction(immediate: true) {
                try resolve(scopeKind: scopeKind, scopeValue: value)
                let reaching = "SELECT capture_id FROM temp.revoking"
                try run("INSERT INTO revocation (revocation_id, sequence, revoked_at, scope_kind, scope_value, reason) VALUES (?, ?, ?, ?, ?, ?)",
                        revocationId, try nextSequence(), revokedAt, scopeKind, value, reason)
                try run("INSERT INTO revoked_capture (capture_id, revocation_id, revoked_at, cascaded) SELECT capture_id, ?, ?, cascaded FROM temp.revoking",
                        revocationId, revokedAt)
                for projection in try rows("SELECT projection_name FROM projection").map({ $0.text(0) }) {
                    let removed = try runCounting("DELETE FROM projection_entry WHERE projection_name = ? AND capture_id IN (\(reaching))", [projection])
                    try run("INSERT INTO projection_revocation (projection_name, revocation_id, applied_at, entries_removed) VALUES (?, ?, ?, ?)",
                            projection, revocationId, Self.iso(Date()), removed)
                }
                let payloads = try runCounting("""
                    DELETE FROM payload_blob WHERE payload_hash IN (
                      SELECT payload_hash FROM capture_event WHERE capture_id IN (\(reaching)) AND payload_hash IS NOT NULL)
                    """, [])
                let contents = try runCounting("DELETE FROM capture_content WHERE capture_id IN (\(reaching))", [])
                let keys = try runCounting("DELETE FROM capture_key WHERE capture_id IN (\(reaching))", [])
                try run("INSERT INTO erasure_receipt (revocation_id, applied_at, keys_destroyed, contents_erased, payloads_erased) VALUES (?, ?, ?, ?, ?)",
                        revocationId, Self.iso(Date()), keys, contents, payloads)
                ids = try rows("SELECT r.capture_id FROM temp.revoking r JOIN capture_event e USING (capture_id) ORDER BY r.cascaded, e.sequence")
                    .map { $0.text(0) }
            }
            // The revocation is committed: from here on, nothing that fails can make it not have
            // happened. A failure finishing the erasure leaves it pending (its receipt has no
            // completed_at), to be finished by the next writer, and says so, rather than reading as
            // nothing forgotten.
            do {
                let erased = try truncateLog()
                let pending = try rows("SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?", revocationId).first?.optionalText(0) == nil
                return Revocation(revocationId: revocationId, revokedCaptureIds: ids, erasedOnDisk: erased && !pending)
            } catch {
                return Revocation(revocationId: revocationId, revokedCaptureIds: ids, erasedOnDisk: false, erasureError: "\(error)")
            }
        }
    }

    /// An erasure a reader held up and that isn't finished yet, by this process or another.
    public var isErasurePending: Bool { lock.withLock { (try? erasurePending()) ?? true } }

    /// Finishes an erasure a reader held up: true once nothing revoked is left in the log.
    public func finishErasure() throws -> Bool {
        try lock.withLock {
            guard try erasurePending() else { return true }
            _ = try truncateLog(attempts: 1)
            return try !erasurePending()
        }
    }

    /// Kept in the store (migration 008), not in this process, so an erasure a process couldn't
    /// finish before it exited is finished by the next writer.
    private func erasurePending() throws -> Bool {
        try !rows("SELECT 1 FROM erasure_receipt WHERE completed_at IS NULL LIMIT 1").isEmpty
    }

    /// The deleted pages, zeroed by secure_delete, are still preceded in the write-ahead log by
    /// the frames that wrote the content: the log is folded in and truncated, so they're gone too.
    /// A reader in another process holding a snapshot blocks that, and SQLite says so only in the
    /// result row (busy = 1), never as an error. Retried for about a second; true once truncated.
    /// Until it is, the erasure isn't reported done and its receipt has no completed_at.
    private func truncateLog(attempts: Int = 20) throws -> Bool {
        // Only the erasures already committed when the checkpoint starts are proven by it. One another
        // writer commits after, while a reader holds the log again, is not, and stays pending.
        let through = try rows("SELECT COALESCE(MAX(sequence), 0) FROM revocation").first?.int(0) ?? 0
        var truncated = false
        do {
            // Retried on its own short schedule, so SQLite's busy wait is off while it tries: with it
            // on, each attempt would wait out the whole busy timeout.
            sqlite3_busy_timeout(db, 0)
            defer { sqlite3_busy_timeout(db, 5000) }
            for attempt in 0..<attempts where !truncated {
                truncated = try rows("PRAGMA wal_checkpoint(TRUNCATE)").first?.int(0) == 0
                if !truncated && attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        if truncated {
            try afterTruncation?()
            try stampErasures(through: through)
        }
        return truncated
    }

    /// For tests: runs after the log is truncated and before the erasures that proves are stamped,
    /// so a test can commit another writer's revocation in between.
    var afterTruncation: (() throws -> Void)?

    /// Every erasure pending through revocation `through` is done: the log holding its frames was
    /// just truncated. Recorded in the store, so it survives this process. If the stamp can't be
    /// written now (another writer held the lock throughout the busy timeout), the receipts stay
    /// pending, which is never wrong, and the next truncation stamps them.
    private func stampErasures(through: Int) throws {
        do {
            try run("""
                UPDATE erasure_receipt SET completed_at = ?
                WHERE completed_at IS NULL AND revocation_id IN (SELECT revocation_id FROM revocation WHERE sequence <= ?)
                """, Self.iso(Date()), through)
        } catch StoreError.sqlite where sqlite3_errcode(db) == SQLITE_BUSY {}
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

    /// Fills temp.revoking with what a revocation reaches: the captures its scope names and everything
    /// derived from them (R10), each with whether it was reached through the chain, less what's already
    /// revoked (erased when it was). The chain is followed through revoked captures too: a store from
    /// before R13 can hold a readable capture derived from one. All in SQL, so a scope of any size (retention's,
    /// from the epoch, takes in every capture ever revoked) never becomes a list of parameters. Kept
    /// in memory (temp_store), never in a file.
    private func resolve(scopeKind: String, scopeValue: String) throws {
        let (clause, values): (String, [Any?])
        switch scopeKind {
        case "capture": (clause, values) = ("capture_id = ?", [scopeValue])
        case "source": (clause, values) = ("(source = ? OR source_app = ?)", [scopeValue, scopeValue])
        case "privacy_level": (clause, values) = ("privacy_level = ?", [scopeValue])
        case "time_range":
            // In the form captured_at is kept in, so "...05Z" can't sort after "...05.999Z".
            let bounds = try Self.canonicalRange(scopeValue).split(separator: "/").map(String.init)
            (clause, values) = ("captured_at >= ? AND captured_at <= ?", bounds)
        default:
            throw StoreError.sqlite("unknown scope kind: \(scopeKind)")
        }
        try exec("CREATE TEMP TABLE IF NOT EXISTS revoking (capture_id TEXT PRIMARY KEY, cascaded INTEGER NOT NULL)")
        try exec("DELETE FROM temp.revoking")
        // Each capture is reached once, by its id alone: a chain that loops back on itself (a capture
        // recorded as derived from itself) ends.
        _ = try runCounting("""
            WITH RECURSIVE reached (capture_id) AS (
              SELECT capture_id FROM capture_event WHERE \(clause)
              UNION
              SELECT e.capture_id FROM capture_event e JOIN reached r ON e.derived_from = r.capture_id
            )
            INSERT INTO temp.revoking (capture_id, cascaded)
            SELECT capture_id, capture_id NOT IN (SELECT capture_id FROM capture_event WHERE \(clause)) FROM reached
            WHERE capture_id NOT IN (SELECT capture_id FROM revoked_capture)
            """, values + values)
    }

    // MARK: SQLite

    private func migrate() throws {
        try exec("CREATE TABLE IF NOT EXISTS schema_migration (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)")
        let applied = { Set(try self.rows("SELECT name FROM schema_migration").map { $0.text(0) }) }
        let pending = try Migrations.all.filter { try !applied().contains($0.name) }
        for migration in pending {
            // Under the write lock, and checked again inside it: two writers opening an older store at
            // once can't both apply the same migration.
            try transaction(immediate: true) {
                guard try !applied().contains(migration.name) else { return }
                try exec(migration.sql)
                try run("INSERT INTO schema_migration (name, applied_at) VALUES (?, ?)", migration.name, Self.iso(Date()))
            }
        }
    }

    private func nextSequence() throws -> Int {
        let sql = """
            SELECT COALESCE(MAX(s), 0) + 1 FROM (
              SELECT MAX(sequence) AS s FROM capture_event UNION ALL SELECT MAX(sequence) AS s FROM revocation
              UNION ALL SELECT MAX(output_sequence) AS s FROM projection_entry)
            """
        return try rows(sql).first?.int(0) ?? 1
    }

    /// `immediate` takes the write lock at once, before anything is read, so a read and the write
    /// that depends on it can't be split by another process's write.
    func transaction(immediate: Bool = false, _ body: () throws -> Void) throws {
        try exec(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func exec(_ sql: String) throws {
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
            // By its length in bytes, not to the first NUL: text can hold one.
            case let text as String: _ = text.withCString { sqlite3_bind_text(statement, position, $0, Int32(text.utf8.count), Self.transient) }
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let data as Data:
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), Self.transient) }
            default: sqlite3_bind_text(statement, position, "\(value!)", -1, Self.transient)
            }
        }
        return statement
    }

    func run(_ sql: String, _ values: Any?...) throws {
        _ = try runCounting(sql, values)
    }

    func runCounting(_ sql: String, _ values: [Any?]) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return Int(sqlite3_changes(db))
    }

    func rows(_ sql: String, _ values: Any?...) throws -> [Row] {
        try rows(sql, values: values)
    }

    /// Named apart from the variadic one: an array passed there would bind as a single value.
    func rows(_ sql: String, values: [Any?]) throws -> [Row] {
        var out: [Row] = []
        try eachRow(sql, values: values) { out.append($0); return true }
        return out
    }

    /// Rows one at a time, as the statement steps, until `body` says stop: a read that needs a few
    /// rows of a long history never holds the rest.
    func eachRow(_ sql: String, values: [Any?], _ body: (Row) throws -> Bool) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if try !body(Row(statement)) { return }
            case SQLITE_DONE: return
            default: throw failure()
            }
        }
    }

    struct Row {
        private var values: [Any?] = []
        init(_ statement: OpaquePointer?) {
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(Int(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT:
                    // By its length in bytes, not to the first NUL.
                    let text = sqlite3_column_text(statement, column)!
                    values.append(String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    values.append(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column)!, count: count))
                default: values.append(nil)
                }
            }
        }
        func text(_ i: Int) -> String { values[i] as? String ?? "" }
        func optionalText(_ i: Int) -> String? { values[i] as? String }
        func int(_ i: Int) -> Int { values[i] as? Int ?? 0 }
        func data(_ i: Int) -> Data { values[i] as? Data ?? Data() }
    }

    // MARK: Time

    /// ISO 8601 with milliseconds, as the reference writes it, so ranges compare as text.
    ///
    /// To the nearest millisecond, written out by hand: the formatter truncates, and a time read back
    /// from text (a range's bounds, a driver's captured_at) can sit a hair under its millisecond, so
    /// it would come back a millisecond early, and a capture in that millisecond could fall outside a
    /// range it's in. Rounded, a time written, read and written again is the same text.
    public static func iso(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (seconds, fraction) = (ms - ((ms % 1000) + 1000) % 1000, ((ms % 1000) + 1000) % 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds / 1000))
            .formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!))
        return whole.dropLast() + String(format: ".%03dZ", fraction)
    }

    /// A time_range's bounds, each in that form.
    static func canonicalRange(_ value: String) throws -> String {
        let bounds = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init).compactMap(date).map(iso)
        guard bounds.count == 2 else { throw StoreError.sqlite("time_range is from/to, each an ISO 8601 time") }
        return bounds.joined(separator: "/")
    }

    public static func date(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
