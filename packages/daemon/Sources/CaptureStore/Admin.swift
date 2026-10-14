import Foundation

/// A grant as `pcap grant list` and Agents Read… show it: who may read what, and until when.
public struct GrantInfo: Sendable, Equatable {
    public let grantId: String
    public let clientId: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let revokedAt: Date?
    public let privacyLevels: [String]
    public let captureTypes: [String]
    public let sources: [String]
    public let maxRowsPerQuery: Int

    /// Neither revoked nor expired.
    public func isActive(at now: Date = Date()) -> Bool { revokedAt == nil && expiresAt > now }
}

/// What one client was served by one tool on one day: counts, never content.
public struct EgressDay: Sendable, Equatable {
    /// The day, as yyyy-MM-dd in the calendar's time zone.
    public let day: String
    public let clientId: String
    public let tool: String
    /// How many reads (egress records).
    public let reads: Int
    /// How many rows those reads served.
    public let rows: Int
    public let bytes: Int
    /// Rows by capture type, from the captures' metadata.
    public let types: [String: Int]
    public let last: Date
}

/// The egress log's hash chain, recomputed from the file.
public struct ChainCheck: Sendable, Equatable {
    public let ok: Bool
    public let records: Int
    /// The first record that doesn't verify, and why: `prev_hash` or `record_hash`.
    public let brokenAt: Int?
    public let reason: String?
}

/// The store's administration (`pcap`, the menu): grants, what agents were served, and checks.
/// Counts and metadata only: nothing here unseals content.
extension CaptureStore {
    /// Every grant, newest first.
    public func grants() throws -> [GrantInfo] {
        try lock.withLock {
            try rows("""
                SELECT grant_id, client_id, issued_at, expires_at, revoked_at, privacy_levels, capture_types, sources, max_rows_per_query
                FROM grant_record ORDER BY issued_at DESC, grant_id
                """).map { row in
                GrantInfo(grantId: row.text(0), clientId: row.text(1), issuedAt: Self.date(row.text(2)) ?? .distantPast,
                          expiresAt: Self.date(row.text(3)) ?? .distantPast, revokedAt: row.optionalText(4).flatMap(Self.date),
                          privacyLevels: Self.strings(row.text(5)), captureTypes: Self.strings(row.text(6)),
                          sources: Self.strings(row.text(7)), maxRowsPerQuery: row.int(8))
            }
        }
    }

    /// What each client was served since `since`, a line per local day, client and tool, newest day
    /// first. The types come from the served captures' metadata, which outlives their revocation.
    public func egress(since: Date, calendar: Calendar = .current) throws -> [EgressDay] {
        let records = try lock.withLock {
            try rows("""
                SELECT r.served_at, r.client_id, r.tool, r.row_count, r.byte_count,
                  (SELECT json_group_object(t, n) FROM (
                     SELECT e.capture_type AS t, COUNT(*) AS n FROM json_each(r.capture_ids) j
                     JOIN capture_event e ON e.capture_id = j.value GROUP BY e.capture_type))
                FROM egress_record r WHERE r.served_at >= ? ORDER BY r.egress_id
                """, Self.iso(since))
        }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        var lines: [String: EgressDay] = [:]
        for row in records {
            let at = Self.date(row.text(0)) ?? .distantPast
            let (day, clientId, tool) = (format.string(from: at), row.text(1), row.text(2))
            let key = "\(day)\u{0}\(clientId)\u{0}\(tool)"
            let types = (try? JSONSerialization.jsonObject(with: Data(row.text(5).utf8))) as? [String: Int] ?? [:]
            let before = lines[key]
            lines[key] = EgressDay(
                day: day, clientId: clientId, tool: tool, reads: (before?.reads ?? 0) + 1,
                rows: (before?.rows ?? 0) + row.int(3), bytes: (before?.bytes ?? 0) + row.int(4),
                types: (before?.types ?? [:]).merging(types, uniquingKeysWith: +), last: max(before?.last ?? .distantPast, at))
        }
        // Newest day first; within a day, by client, then tool.
        return lines.values.sorted { a, b in
            if a.day != b.day { return a.day > b.day }
            return (a.clientId, a.tool) < (b.clientId, b.tool)
        }
    }

    /// Recomputes the egress log's hash chain from the file, as the reference's verifyEgressChain
    /// does: a record edited, removed or inserted out of order breaks it.
    public func verifyEgressChain() throws -> ChainCheck {
        let records = try lock.withLock {
            try rows("""
                SELECT egress_id, served_at, client_id, grant_id, tool, query_fingerprint, capture_ids, privacy_levels_served,
                  row_count, byte_count, prev_hash, record_hash FROM egress_record ORDER BY egress_id
                """)
        }
        var previous = Self.genesisHash
        for row in records {
            if row.text(10) != previous { return ChainCheck(ok: false, records: records.count, brokenAt: row.int(0), reason: "prev_hash") }
            let hash = Self.egressHash(servedAt: row.text(1), clientId: row.text(2), grantId: row.text(3), tool: row.text(4),
                                       queryFingerprint: row.text(5), captureIds: Self.strings(row.text(6)),
                                       privacyLevelsServed: Self.strings(row.text(7)), rowCount: row.int(8), byteCount: row.int(9),
                                       prevHash: previous)
            if hash != row.text(11) { return ChainCheck(ok: false, records: records.count, brokenAt: row.int(0), reason: "record_hash") }
            previous = hash
        }
        return ChainCheck(ok: true, records: records.count, brokenAt: nil, reason: nil)
    }

    /// SQLite's own check of the file's structure: "ok", or what's wrong.
    public func quickCheck() throws -> String {
        try lock.withLock { try rows("PRAGMA quick_check").map { $0.text(0) }.joined(separator: "\n") }
    }

    /// A JSON array of strings, as grants and egress records keep their lists.
    static func strings(_ json: String) -> [String] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String] ?? []
    }
}
