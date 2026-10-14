import Foundation

/// Activity sessions (ADR 0008): computed in memory from activity captures, never stored, so
/// revoking any capture behind one just changes what's computed next. The same rules as the
/// reference's src/sessions.js, held to packages/schema/cases/sessions.json.
public enum Sessions {
    /// One activity capture: when it began, the person's state, and the app and window in front
    /// (neither, for an excluded one).
    public struct Activity: Sendable {
        public var id: String
        public var at: String
        public var state: String
        public var app: String?
        public var window: String?
        public var excluded: Bool

        public init(id: String, at: String, state: String, app: String? = nil, window: String? = nil, excluded: Bool = false) {
            (self.id, self.at, self.state, self.app, self.window, self.excluded) = (id, at, state, app, window, excluded)
        }

        var key: String { excluded ? "\u{0}excluded" : "\(app ?? "")\u{0}\(window ?? "")" }
    }

    /// A session: ids and times only. What it was is in its captures' envelopes.
    public struct Session: Equatable, Sendable {
        public var id: String
        public var startedAt: String
        /// When the capture that ended it began; nil while it goes on.
        public var endedAt: String?
        public var captureIds: [String]
    }

    static let interruption: TimeInterval = 30

    /// `activity` in the order it was captured; `now` ends the last capture's time.
    public static func of(_ activity: [Activity], now: String) -> [Session] {
        let seconds = { (text: String) in CaptureStore.date(text)?.timeIntervalSince1970 ?? 0 }
        let ends = activity.indices.map { $0 + 1 < activity.count ? activity[$0 + 1].at : now }
        let length = { (i: Int) in seconds(ends[i]) - seconds(activity[i].at) }
        var sessions: [Session] = []
        var current: (key: String, session: Session)?
        func close(_ at: String?) {
            if var session = current?.session {
                session.endedAt = at
                sessions.append(session)
            }
            current = nil
        }

        var i = 0
        while i < activity.count {
            let span = activity[i]
            if span.state != "active" {
                close(span.at)
                i += 1
                continue
            }
            if let open = current, open.key == span.key {
                current?.session.captureIds.append(span.id)
                i += 1
                continue
            }
            if let open = current {
                // Other active captures, under the interruption length in all, then back to the same
                // app and window: taken into the session.
                var j = i
                var total: TimeInterval = 0
                while j < activity.count, activity[j].state == "active", activity[j].key != open.key, total + length(j) < interruption {
                    total += length(j)
                    j += 1
                }
                if j > i, j < activity.count, activity[j].state == "active", activity[j].key == open.key {
                    current?.session.captureIds += activity[i..<j].map(\.id)
                    i = j
                    continue
                }
                close(span.at)
            }
            current = (span.key, Session(id: "ses_\(span.id)", startedAt: span.at, endedAt: nil, captureIds: [span.id]))
            i += 1
        }
        close(nil)
        return sessions
    }
}
