import CryptoKit
import Foundation

/// JSON written exactly as ECMAScript's JSON.stringify writes it: keys in the order given, no
/// whitespace, and only `"`, `\` and U+0000 to U+001F escaped. The egress log's record hashes and
/// byte counts are over this form (SCHEMA.md), so a log written here verifies in the reference
/// and the other way round.
public indirect enum CanonicalJSON: Equatable, Sendable {
    case string(String)
    case int(Int)
    case null
    case array([CanonicalJSON])
    case object([(String, CanonicalJSON)])

    public static func == (a: CanonicalJSON, b: CanonicalJSON) -> Bool { a.text == b.text }

    public var text: String {
        switch self {
        case .string(let s): return Self.quote(s)
        case .int(let n): return String(n)
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { Self.quote($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    /// As Foundation objects, for a JSON encoder that doesn't keep order.
    public var foundation: Any {
        switch self {
        case .string(let s): return s
        case .int(let n): return n
        case .null: return NSNull()
        case .array(let items): return items.map(\.foundation)
        case .object(let pairs): return Dictionary(pairs.map { ($0.0, $0.1.foundation) }, uniquingKeysWith: { a, _ in a })
        }
    }

    public static func optional(_ s: String?) -> CanonicalJSON { s.map(CanonicalJSON.string) ?? .null }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// A grant to issue (ADR 0001 §4.1): a client, an expiry, and what it may read.
public struct NewGrant: Sendable {
    public var clientId: String
    public var expiresAt: Date
    public var privacyLevels: [String] = ["standard"]
    public var captureTypes: [String] = ["*"]
    public var sources: [String] = ["*"]
    public var domains: [String] = ["*"]
    public var timeFrom: Date?
    public var timeTo: Date?
    public var maxRowsPerQuery = 100

    public init(clientId: String, expiresAt: Date) {
        self.clientId = clientId
        self.expiresAt = expiresAt
    }
}

/// One read: the tool asking, its query (fingerprinted for the log, never kept), and filters.
public struct ReadRequest: Sendable {
    public var tool: String
    public var query = ""
    public var contains: String?
    public var limit: Int?
    public var afterSequence: Int?

    public init(tool: String, query: String = "", contains: String? = nil, limit: Int? = nil, afterSequence: Int? = nil) {
        (self.tool, self.query, self.contains, self.limit, self.afterSequence) = (tool, query, contains, limit, afterSequence)
    }
}

/// The read path (ADR 0001), the same as the reference's: grants are enforced here, below any tool,
/// so a tool that forgets to filter still can't over-serve; every payload leaves inside the
/// untrusted envelope; every served row is recorded in the hash-chained egress log.
extension CaptureStore {
    static let envelopeVersion = "1"
    static let genesisHash = String(repeating: "0", count: 64)

    @discardableResult
    public func issueGrant(_ grant: NewGrant) throws -> String {
        try lock.withLock {
            let grantId = "grn_\(UUID().uuidString.lowercased())"
            let list = { (items: [String]) in CanonicalJSON.array(items.map(CanonicalJSON.string)).text }
            try run("""
                INSERT INTO grant_record (
                  grant_id, client_id, issued_at, expires_at, domains, time_from, time_to,
                  privacy_levels, capture_types, sources, max_rows_per_query, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                grantId, grant.clientId, Self.iso(Date()), Self.iso(grant.expiresAt), list(grant.domains),
                grant.timeFrom.map(Self.iso), grant.timeTo.map(Self.iso), list(grant.privacyLevels), list(grant.captureTypes),
                list(grant.sources), grant.maxRowsPerQuery)
            return grantId
        }
    }

    /// How many captures there are, and how many are revoked: counts only, for diagnostics.
    public func counts() throws -> (captures: Int, revoked: Int) {
        try lock.withLock {
            (try rows("SELECT COUNT(*) FROM capture_event").first?.int(0) ?? 0,
             try rows("SELECT COUNT(*) FROM revoked_capture").first?.int(0) ?? 0)
        }
    }

    /// The highest capture sequence: a number, never content, so a reader can tell whether there's
    /// anything new to read before reading (and recording) it.
    public func latestSequence() throws -> Int {
        try lock.withLock { try rows("SELECT COALESCE(MAX(sequence), 0) FROM capture_event").first?.int(0) ?? 0 }
    }

    /// How far revocation has got (its highest sequence), and the captures revoked by revocations after
    /// `sequence` up to there, read together: ids and numbers only, so a reader can evict them and move
    /// its cursor past every revocation, one that revoked nothing new included.
    public func revoked(after sequence: Int) throws -> (through: Int, captureIds: [String]) {
        try lock.withLock {
            var out = (through: sequence, captureIds: [String]())
            try transaction {
                let through = try rows("SELECT COALESCE(MAX(sequence), 0) FROM revocation").first?.int(0) ?? 0
                let ids = try rows("""
                    SELECT rc.capture_id FROM revoked_capture rc JOIN revocation r ON r.revocation_id = rc.revocation_id
                    WHERE r.sequence > ? AND r.sequence <= ?
                    """, sequence, through).map { $0.text(0) }
                out = (max(through, sequence), ids)
            }
            return out
        }
    }

    public func revokeGrant(_ grantId: String) throws {
        try lock.withLock { try run("UPDATE grant_record SET revoked_at = ? WHERE grant_id = ?", Self.iso(Date()), grantId) }
    }

    /// What the grant allows of what the request asks, enveloped, in sequence order, and logged.
    public func read(grantId: String, _ request: ReadRequest) throws -> [CanonicalJSON] {
        try twoPhase(grantId: grantId, tool: request.tool, query: request.query, contains: request.contains) { grant in
            var (clauses, params) = admits(grant)
            if let after = request.afterSequence { clauses.append("e.sequence > ?"); params.append(after) }
            let maximum = grant.int(9)
            let cap = min(request.limit ?? maximum, maximum)
            let needle = request.contains?.lowercased()
            var chosen: [Chosen] = []
            // Stepped one row at a time, stopping at the cap: a short read of a long history holds
            // only what it serves.
            try eachRow("""
                SELECT \(Self.provenanceColumns) FROM capture_event e
                WHERE \(clauses.joined(separator: " AND ")) ORDER BY e.sequence
                """, values: params) { row in
                guard chosen.count < cap else { return false }
                let content = try unsealedText(row.text(0))
                if let needle, !(content?.lowercased().contains(needle) ?? false) { return true }
                chosen.append(Chosen(row: row, content: content))
                return chosen.count < cap
            }
            return chosen
        }
    }

    /// The captures named, in the order named, through the grant: how a ranked result (a search's) is
    /// served. What the grant doesn't admit, or is revoked, is left out, a capture named twice is served
    /// once, and no more than the grant's cap is served.
    public func readCaptures(grantId: String, tool: String, query: String = "", captureIds: [String]) throws -> [CanonicalJSON] {
        try twoPhase(grantId: grantId, tool: tool, query: query, contains: nil) { grant in
            let (clauses, params) = admits(grant)
            var chosen: [Chosen] = []
            var seen = Set<String>()
            for id in captureIds where seen.insert(id).inserted {
                guard chosen.count < grant.int(9) else { break }
                guard let row = try rows("""
                    SELECT \(Self.provenanceColumns) FROM capture_event e
                    WHERE \((clauses + ["e.capture_id = ?"]).joined(separator: " AND "))
                    """, values: params + [id]).first else { continue }
                chosen.append(Chosen(row: row, content: try unsealedText(id)))
            }
            return chosen
        }
    }

    /// Projection outputs (an embedding, a summary) of the captures the grant admits, in the order they
    /// were written (output_sequence, migration 010), after `afterOutputSequence`, up to the grant's cap.
    /// Each is enveloped with its capture's provenance, and its content is the output's JSON as text.
    public func readOutputs(grantId: String, tool: String, kind: String? = nil, afterOutputSequence: Int = 0, limit: Int? = nil) throws -> [CanonicalJSON] {
        try twoPhase(grantId: grantId, tool: tool, query: kind ?? "", contains: nil) { grant in
            var (clauses, params) = admits(grant)
            clauses += ["p.output_sealed IS NOT NULL", "p.output_sequence > ?"]
            params.append(afterOutputSequence)
            if let kind { clauses.append("p.output_kind = ?"); params.append(kind) }
            let maximum = grant.int(9)
            let cap = min(limit ?? maximum, maximum)
            var chosen: [Chosen] = []
            try eachRow("""
                SELECT \(Self.provenanceColumns), p.projection_name, p.entry_ref, p.output_kind, p.output_sequence, p.output_sealed, k.wrapped_key
                FROM projection_entry p
                JOIN capture_event e ON e.capture_id = p.capture_id
                JOIN capture_key k ON k.capture_id = p.capture_id
                WHERE \(clauses.joined(separator: " AND ")) ORDER BY p.output_sequence
                """, values: params) { row in
                guard chosen.count < cap else { return false }
                let id = row.text(0)
                let key = try dataKey(id, wrapped: row.data(13))
                let json = try Seal.open(row.data(12), key: key, aad: "projection:\(row.text(8)):\(id):\(row.text(9))")
                chosen.append(Chosen(row: row, content: String(decoding: json, as: UTF8.self), output: [
                    ("projection", .string(row.text(8))), ("entry_ref", .string(row.text(9))),
                    ("output_kind", .optional(row.optionalText(10))), ("output_sequence", .int(row.int(11))),
                ]))
                return chosen.count < cap
            }
            return chosen
        }
    }

    /// What one read chose to serve: a capture's metadata (the provenance columns, in order), its
    /// content, and, for an output, where it came from.
    private struct Chosen {
        let row: Row
        let content: String?
        var output: [(String, CanonicalJSON)] = []

        var id: String { row.text(0) }
        var level: String { row.text(6) }

        /// Every payload crosses the boundary wrapped (ADR 0001 §4.3). Provenance comes from the
        /// capture's metadata, never from its content (T10); an output adds where it came from after
        /// the capture's own.
        var envelope: CanonicalJSON {
            .object([("presence_capture_untrusted", .object([
                ("envelope_version", .string(CaptureStore.envelopeVersion)),
                ("provenance", .object([
                    ("capture_id", .string(row.text(0))), ("sequence", .int(row.int(1))), ("captured_at", .string(row.text(2))),
                    ("source_app", .optional(row.optionalText(3))), ("source_url", .optional(row.optionalText(4))),
                    ("capture_type", .string(row.text(5))), ("privacy_level", .string(row.text(6))),
                    ("extraction", .optional(row.optionalText(7))),
                ] + output)),
                ("content", .optional(content)),
            ]))])
        }
    }

    private static let provenanceColumns =
        "e.capture_id, e.sequence, e.captured_at, e.source_app, e.source_url, e.capture_type, e.privacy_level, e.extraction"

    /// Every read has two parts. What the grant admits is chosen and unsealed under a read snapshot,
    /// which never holds the write lock, so a search through a long history doesn't keep the daemon,
    /// or a Forget, waiting while it reads. Then it's served only once the grant is checked again and
    /// the serving recorded, in one transaction under the write lock (BEGIN IMMEDIATE): a grant revoked
    /// meanwhile serves nothing, a capture revoked meanwhile isn't served (R2), and every row served is
    /// recorded, chained to the record before it (migration 007 refuses a fork besides).
    private func twoPhase(grantId: String, tool: String, query: String, contains: String?,
                          choose: (Row) throws -> [Chosen]) throws -> [CanonicalJSON] {
        try lock.withLock {
            var chosen: [Chosen] = []
            try transaction { chosen = try choose(try authorizedGrant(grantId)) }
            var served: [CanonicalJSON] = []
            try transaction(immediate: true) {
                let grant = try authorizedGrant(grantId)
                let kept = try chosen.filter { try !isRevoked($0.id) }
                var levelsServed: [String] = []
                for item in kept where !levelsServed.contains(item.level) { levelsServed.append(item.level) }
                let fingerprint = SHA256.hash(data: Data("\(tool)\u{0}\(query)\u{0}\(contains ?? "")".utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let envelopes = kept.map(\.envelope)
                try appendEgressLocked(
                    clientId: grant.text(0), grantId: grantId, tool: tool, queryFingerprint: fingerprint,
                    captureIds: kept.map(\.id), privacyLevelsServed: levelsServed,
                    byteCount: CanonicalJSON.array(envelopes).text.utf8.count)
                served = envelopes
            }
            return served
        }
    }

    /// The grant a read is made under, as it is now: refused when it's missing, revoked or expired.
    private func authorizedGrant(_ grantId: String) throws -> Row {
        guard let grant = try rows("""
            SELECT client_id, expires_at, revoked_at, domains, time_from, time_to, privacy_levels, capture_types, sources, max_rows_per_query
            FROM grant_record WHERE grant_id = ?
            """, grantId).first else { throw StoreError.denied("no grant: default deny") }
        if grant.optionalText(2) != nil { throw StoreError.denied("grant revoked") }
        if grant.text(1) <= Self.iso(Date()) { throw StoreError.denied("grant expired") }
        return grant
    }

    /// The SQL a grant admits captures by: privacy levels, types, domains, sources and time.
    private func admits(_ grant: Row) -> (clauses: [String], params: [Any?]) {
        let decode = { (i: Int) -> [String] in
            (try? JSONSerialization.jsonObject(with: Data(grant.text(i).utf8)) as? [String]) ?? []
        }
        let (domains, levels, types, sources) = (decode(3), decode(6), decode(7), decode(8))
        // sacred_mode can never appear here: the CHECK in 004 refuses a grant that names it.
        var clauses = ["e.capture_id NOT IN (SELECT capture_id FROM revoked_capture)"]
        var params: [Any?] = []
        func among(_ column: String, _ values: [String]) {
            clauses.append("\(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
            params += values
        }
        among("e.privacy_level", levels)
        if !types.contains("*") { among("e.capture_type", types) }
        if !domains.contains("*") { among("e.classification", domains) }
        if !sources.contains("*") { among("e.source", sources) }
        if let from = grant.optionalText(4) { clauses.append("e.captured_at >= ?"); params.append(from) }
        if let to = grant.optionalText(5) { clauses.append("e.captured_at <= ?"); params.append(to) }
        return (clauses, params)
    }

    /// A capture's text, unsealed, for a caller already holding the lock.
    private func unsealedText(_ captureId: String) throws -> String? {
        guard let row = try rows("""
            SELECT k.wrapped_key, c.text_sealed FROM capture_content c
            JOIN capture_key k ON k.capture_id = c.capture_id WHERE c.capture_id = ?
            """, captureId).first else { return nil }
        let key = try dataKey(captureId, wrapped: row.data(0))
        return String(decoding: try Seal.open(row.data(1), key: key, aad: "text:\(captureId)"), as: UTF8.self)
    }

    /// One record of what was served, chained to the one before it (ADR 0001 §4.2, SCHEMA.md), for a
    /// read holding the write lock.
    private func appendEgressLocked(clientId: String, grantId: String, tool: String, queryFingerprint: String,
                                    captureIds: [String], privacyLevelsServed: [String], byteCount: Int) throws {
        let previous = try rows("SELECT record_hash FROM egress_record ORDER BY egress_id DESC LIMIT 1").first?.text(0) ?? Self.genesisHash
        let servedAt = Self.iso(Date())
        let strings = { (items: [String]) in CanonicalJSON.array(items.map(CanonicalJSON.string)) }
        let canonical = CanonicalJSON.object([
            ("servedAt", .string(servedAt)), ("clientId", .string(clientId)), ("grantId", .string(grantId)), ("tool", .string(tool)),
            ("queryFingerprint", .string(queryFingerprint)), ("captureIds", strings(captureIds)),
            ("privacyLevelsServed", strings(privacyLevelsServed)), ("rowCount", .int(captureIds.count)), ("byteCount", .int(byteCount)),
            ("prevHash", .string(previous)),
        ]).text
        let recordHash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        try run("""
            INSERT INTO egress_record (served_at, client_id, grant_id, tool, query_fingerprint, capture_ids,
              privacy_levels_served, row_count, byte_count, prev_hash, record_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            servedAt, clientId, grantId, tool, queryFingerprint, strings(captureIds).text, strings(privacyLevelsServed).text,
            captureIds.count, byteCount, previous, recordHash)
    }
}
