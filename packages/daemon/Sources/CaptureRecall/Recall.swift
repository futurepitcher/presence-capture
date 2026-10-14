import CaptureStore
import Foundation

/// What this reader recalls from (ADR 0008): every capture its grant admits, unsealed into memory
/// and nowhere else. Keyword search is SQLite FTS5 in `:memory:`; sessions are computed from activity
/// when asked for. The same tools, arguments and answers as the reference's src/recall.js, held to
/// the same MCP conformance.
///
/// It's built by reading through the grant, so the store enforces the grant and records every row
/// this reader unsealed in the egress log (tool `index`). It's kept current on each call: captures
/// after the last one read, and revocations after the last one seen, which are evicted. Whatever it
/// ranks is then served by id through the grant again, so nothing it holds is served without the
/// store's say: a capture revoked or a grant withdrawn since serves nothing.
///
/// Search by meaning isn't here for 0.1: Apple's on-device sentence embedding, measured on the eval,
/// found 1 of 25 paraphrased questions among 15,000 captures and made fused results worse (ADR 0008,
/// amended). It waits for a stronger model, on the branch wip/embeddings-0.2.
public final class Recall {
    private let store: CaptureStore
    private let grantId: String
    private let memory = MemoryIndex()
    private var afterSequence = 0
    private var afterRevocation = 0

    public init(store: CaptureStore, grantId: String) {
        self.store = store
        self.grantId = grantId
        memory.exec("""
            CREATE TABLE doc (
              capture_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL, captured_at TEXT NOT NULL,
              capture_type TEXT NOT NULL, source TEXT, source_app TEXT, content TEXT
            );
            CREATE INDEX doc_time ON doc (captured_at);
            CREATE VIRTUAL TABLE words USING fts5(capture_id UNINDEXED, content);
            """)
    }

    /// Runs a tool, after bringing memory up to date with the store.
    public func call(_ name: String, _ args: [String: Any]) throws -> CanonicalJSON {
        guard ["search", "recent", "timeline", "transcript", "now", "session"].contains(name) else { throw ToolError.unknown(name) }
        try refresh()
        switch name {
        case "search": return .array(try search(args))
        case "recent": return .array(try serve("recent", "recent", memory.ids("SELECT capture_id FROM doc ORDER BY sequence DESC LIMIT ?", try limit(args, 10))))
        case "timeline": return .array(try timeline(args))
        case "transcript": return .array(try transcript(args))
        case "now": return try now()
        default: return try session(args)
        }
    }

    // MARK: Keeping memory current

    private func refresh() throws {
        let latest = try store.latestSequence()
        while afterSequence < latest {
            let page = try store.read(grantId: grantId, ReadRequest(tool: "index", query: "index", afterSequence: afterSequence))
            if page.isEmpty { break }
            // Where each came from (the envelope doesn't say): dictation is the microphone too, though
            // its source_app is the app it was typed into.
            let sources = try store.sources(of: page.map { Self.parts($0).provenance["capture_id"] as? String ?? "" })
            for envelope in page {
                let (provenance, content) = Self.parts(envelope)
                let id = provenance["capture_id"] as? String ?? ""
                let sequence = (provenance["sequence"] as? NSNumber)?.intValue ?? 0
                memory.run("""
                    INSERT INTO doc (capture_id, sequence, captured_at, capture_type, source, source_app, content) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (capture_id) DO NOTHING
                    """, id, sequence, provenance["captured_at"] as? String ?? "", provenance["capture_type"] as? String ?? "",
                    sources[id], provenance["source_app"] as? String, content)
                if let content { memory.run("INSERT INTO words (capture_id, content) VALUES (?, ?)", id, content) }
                afterSequence = max(afterSequence, sequence)
            }
        }
        // Every revocation since the last look, one that revoked nothing new included: the cursor moves
        // past all of them, so none is taken for a change still to come.
        let (through, revoked) = try store.revoked(after: afterRevocation)
        for id in revoked {
            memory.run("DELETE FROM doc WHERE capture_id = ?", id)
            memory.run("DELETE FROM words WHERE capture_id = ?", id)
        }
        afterRevocation = through
    }

    private static func parts(_ envelope: CanonicalJSON) -> (provenance: [String: Any], content: String?) {
        let inner = (envelope.foundation as? [String: Any])?["presence_capture_untrusted"] as? [String: Any] ?? [:]
        return (inner["provenance"] as? [String: Any] ?? [:], inner["content"] as? String)
    }

    /// Served by id, through the grant, in the order ranked. Every answer goes through here, an empty
    /// one too, so every answer is authorized and recorded.
    private func serve(_ tool: String, _ query: String, _ ids: [String]) throws -> [CanonicalJSON] {
        try store.readCaptures(grantId: grantId, tool: tool, query: query, captureIds: ids)
    }

    // MARK: Tools

    /// Keyword search, ranked by BM25: any word of the query, as many results as asked for.
    private func search(_ args: [String: Any]) throws -> [CanonicalJSON] {
        guard let query = args["query"] as? String else { throw ToolError.invalid("query must be text") }
        let (from, to, max) = (try time(args, "from") ?? "0000-01-01T00:00:00.000Z", try time(args, "to") ?? "9999-12-31T23:59:59.999Z", try limit(args, 10))
        let words = Self.words(query)
        guard !words.isEmpty else { return try serve("search", query, []) }
        let ids = memory.ids("""
            SELECT words.capture_id FROM words JOIN doc ON doc.capture_id = words.capture_id
            WHERE words MATCH ? AND doc.captured_at >= ? AND doc.captured_at <= ?
            ORDER BY bm25(words), doc.sequence DESC LIMIT ?
            """, words.map { "\"\($0)\"" }.joined(separator: " OR "), from, to, max)
        return try serve("search", query, ids)
    }

    /// Everything captured between two times (by default the last hour), in the order captured.
    private func timeline(_ args: [String: Any]) throws -> [CanonicalJSON] {
        let (start, end) = try span(args)
        let ids = memory.ids("SELECT capture_id FROM doc WHERE captured_at >= ? AND captured_at <= ? ORDER BY captured_at, sequence LIMIT ?",
                             start, end, try limit(args, 100))
        return try serve("timeline", "\(start)/\(end)", ids)
    }

    /// What was said between two times, in order: from the microphone (input), this Mac (output), or both.
    private func transcript(_ args: [String: Any]) throws -> [CanonicalJSON] {
        let device = args["device"].flatMap { $0 is NSNull ? nil : $0 }
        guard device == nil || ["input", "output"].contains(device as? String ?? "") else { throw ToolError.invalid("device must be input or output") }
        let (start, end) = try span(args)
        let which = device as? String
        // The microphone is ambient speech from it and dictation; this Mac is what it played.
        let filter = ["input": "AND (source_app = 'input' OR source = 'dictation')", "output": "AND source_app = 'output'"][which ?? ""] ?? ""
        let ids = memory.ids("""
            SELECT capture_id FROM doc WHERE capture_type = 'audio_transcript' AND captured_at >= ? AND captured_at <= ? \(filter)
            ORDER BY captured_at, sequence LIMIT ?
            """, start, end, try limit(args, 100))
        return try serve("transcript", "\(start)/\(end)/\(which ?? "")", ids)
    }

    private static let never = "9999-12-31T23:59:59.999Z"

    /// What the person is doing now: the latest session; the latest activity, which says so if the
    /// person is idle or locked now (or has been only that so far, with no session yet); the
    /// session's latest screen text; and everything said in the five minutes before this call, newest
    /// first, so a grant's row cap drops the oldest.
    private func now() throws -> CanonicalJSON {
        try consistent {
            let session = sessions().last
            let latest = memory.ids("SELECT capture_id FROM doc WHERE capture_type = 'activity' ORDER BY captured_at DESC, sequence DESC LIMIT 1")
            let screen = session.map { session in
                memory.ids("""
                    SELECT capture_id FROM doc WHERE capture_type = 'screen_text' AND captured_at >= ? AND captured_at < ?
                    ORDER BY captured_at DESC, sequence DESC LIMIT 1
                    """, session.startedAt, session.endedAt ?? Self.never)
            } ?? []
            let said = memory.ids("""
                SELECT capture_id FROM doc WHERE capture_type = 'audio_transcript' AND captured_at >= ?
                ORDER BY captured_at DESC, sequence DESC
                """, CaptureStore.iso(Date().addingTimeInterval(-5 * 60)))
            var wanted: [String] = []
            for id in [session?.captureIds.last].compactMap({ $0 }) + latest + screen + said where !wanted.contains(id) { wanted.append(id) }
            return Self.result(session, try serve("now", "now", wanted))
        }
    }

    /// One session, by id, and everything captured during it, in order: from its start up to, not
    /// including, the capture that ended it.
    private func session(_ args: [String: Any]) throws -> CanonicalJSON {
        guard let id = args["id"] as? String else { throw ToolError.invalid("id must be a session id") }
        let max = try limit(args, 100)
        return try consistent {
            guard let session = sessions().first(where: { $0.id == id }) else { return Self.result(nil, try serve("session", id, [])) }
            let ids = memory.ids("SELECT capture_id FROM doc WHERE captured_at >= ? AND captured_at < ? ORDER BY captured_at, sequence LIMIT ?",
                                 session.startedAt, session.endedAt ?? Self.never, max)
            return Self.result(session, try serve("session", id, ids))
        }
    }

    /// A session answer computed from memory and served through the grant, with nothing revoked in
    /// between: a session is derived from several captures, and the store only re-checks the
    /// envelopes it serves. If anything was revoked meanwhile, memory is brought up to date and the
    /// answer computed again.
    private func consistent(_ answer: () throws -> CanonicalJSON) throws -> CanonicalJSON {
        for _ in 0..<3 {
            let result = try answer()
            if try store.revoked(after: afterRevocation).through == afterRevocation { return result }
            try refresh()
        }
        // Never an answer known to be stale: the caller can ask again.
        throw ToolError.changed("captures were revoked while this was being answered, three times over: ask again")
    }

    private func sessions() -> [Sessions.Session] {
        let activity = memory.rows("SELECT capture_id, captured_at, content FROM doc WHERE capture_type = 'activity' ORDER BY captured_at, sequence").map { row in
            let seen = (row[2] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            return Sessions.Activity(id: row[0] as? String ?? "", at: row[1] as? String ?? "", state: seen["state"] as? String ?? "active",
                                     app: seen["app"] as? String, window: seen["window"] as? String, excluded: seen["excluded"] as? Bool ?? false)
        }
        return Sessions.of(activity, now: CaptureStore.iso(Date()))
    }

    /// A session tool's answer: the session (ids and times only), and its captures' envelopes.
    private static func result(_ session: Sessions.Session?, _ envelopes: [CanonicalJSON]) -> CanonicalJSON {
        let described: CanonicalJSON = session.map {
            .object([("id", .string($0.id)), ("started_at", .string($0.startedAt)), ("ended_at", .optional($0.endedAt)),
                     ("capture_ids", .array($0.captureIds.map(CanonicalJSON.string)))])
        } ?? .null
        return .object([("session", described), ("envelopes", .array(envelopes))])
    }

    // MARK: Arguments

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    static func words(_ text: String) -> [String] {
        wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// A time argument, as the store writes times; nil when it's not given.
    /// A date and a time to the second (a fraction allowed), with a zone: Z, or an offset of hours and
    /// minutes. The same pattern the reference server checks (packages/mcp/src/recall.js): the
    /// formatter alone would take more (an offset of hours alone, "GMT").
    private static let isoTime = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})$"#)

    private func time(_ args: [String: Any], _ name: String) throws -> String? {
        guard let value = args[name], !(value is NSNull) else { return nil }
        guard let text = value as? String,
              Self.isoTime.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              let date = CaptureStore.date(text) else { throw ToolError.invalid("\(name) must be an ISO 8601 time") }
        return CaptureStore.iso(date)
    }

    /// `from` and `to`, by default the hour up to now.
    private func span(_ args: [String: Any]) throws -> (String, String) {
        let end = try time(args, "to") ?? CaptureStore.iso(Date())
        let start = try time(args, "from") ?? CaptureStore.iso((CaptureStore.date(end) ?? Date()).addingTimeInterval(-3600))
        return (start, end)
    }

    private func limit(_ args: [String: Any], _ fallback: Int) throws -> Int {
        guard let value = args["limit"], !(value is NSNull) else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let whole = Int(exactly: number.doubleValue), whole >= 1 else { throw ToolError.invalid("limit must be a whole number, 1 or more") }
        return whole
    }
}

public enum ToolError: Error {
    case unknown(String)
    /// A malformed argument: the caller's error, answered as invalid params, and nothing is served.
    case invalid(String)
    /// What an answer was computed from kept changing while it was served: the caller can ask again.
    case changed(String)
}
