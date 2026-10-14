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

    static func optional(_ s: String?) -> CanonicalJSON { s.map(CanonicalJSON.string) ?? .null }

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

    public func revokeGrant(_ grantId: String) throws {
        try lock.withLock { try run("UPDATE grant_record SET revoked_at = ? WHERE grant_id = ?", Self.iso(Date()), grantId) }
    }

    /// What the grant allows of what the request asks, enveloped, in sequence order, and logged.
    ///
    /// Chosen and unsealed under a read snapshot, which never holds the write lock, so a search
    /// through a long history doesn't keep the daemon, or a Forget, waiting while it reads. Then
    /// served only once the grant is checked again and the serving recorded, in one transaction under
    /// the write lock (BEGIN IMMEDIATE): a grant revoked meanwhile serves nothing, a capture revoked
    /// meanwhile isn't served (R2), and every row served is recorded, chained to the record before it
    /// (migration 007 refuses a fork besides).
    public func read(grantId: String, _ request: ReadRequest) throws -> [CanonicalJSON] {
        try lock.withLock {
            var chosen: [(id: String, level: String, envelope: CanonicalJSON)] = []
            try transaction { chosen = try admitted(by: try authorizedGrant(grantId), request) }
            var served: [CanonicalJSON] = []
            try transaction(immediate: true) {
                let grant = try authorizedGrant(grantId)
                let kept = try chosen.filter { try !isRevoked($0.id) }
                var levelsServed: [String] = []
                for item in kept where !levelsServed.contains(item.level) { levelsServed.append(item.level) }
                let fingerprint = SHA256.hash(data: Data("\(request.tool)\u{0}\(request.query)\u{0}\(request.contains ?? "")".utf8))
                    .map { String(format: "%02x", $0) }.joined()
                try appendEgressLocked(
                    clientId: grant.text(0), grantId: grantId, tool: request.tool, queryFingerprint: fingerprint,
                    captureIds: kept.map(\.id), privacyLevelsServed: levelsServed,
                    byteCount: CanonicalJSON.array(kept.map(\.envelope)).text.utf8.count)
                served = kept.map(\.envelope)
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

    /// The captures a grant admits, in sequence order, enveloped with their text unsealed, up to its cap.
    private func admitted(by grant: Row, _ request: ReadRequest) throws -> [(id: String, level: String, envelope: CanonicalJSON)] {
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
        if let after = request.afterSequence { clauses.append("e.sequence > ?"); params.append(after) }

        let maximum = grant.int(9)
        let cap = min(request.limit ?? maximum, maximum)
        let needle = request.contains?.lowercased()
        var served: [(id: String, level: String, envelope: CanonicalJSON)] = []
        // Stepped one row at a time, stopping at the cap: a short read of a long history holds
        // only what it serves.
        try eachRow("""
            SELECT e.capture_id, e.sequence, e.captured_at, e.source_app, e.source_url, e.capture_type, e.privacy_level, e.extraction
            FROM capture_event e WHERE \(clauses.joined(separator: " AND ")) ORDER BY e.sequence
            """, values: params) { row in
            guard served.count < cap else { return false }
            let id = row.text(0)
            let content = try unsealedText(id)
            if let needle, !(content?.lowercased().contains(needle) ?? false) { return true }
            // Provenance comes from the capture's metadata, never from its content (T10).
            let envelope = CanonicalJSON.object([("presence_capture_untrusted", .object([
                ("envelope_version", .string(Self.envelopeVersion)),
                ("provenance", .object([
                    ("capture_id", .string(id)), ("sequence", .int(row.int(1))), ("captured_at", .string(row.text(2))),
                    ("source_app", .optional(row.optionalText(3))), ("source_url", .optional(row.optionalText(4))),
                    ("capture_type", .string(row.text(5))), ("privacy_level", .string(row.text(6))),
                    ("extraction", .optional(row.optionalText(7))),
                ])),
                ("content", .optional(content)),
            ]))])
            served.append((id, row.text(6), envelope))
            return served.count < cap
        }
        return served
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
