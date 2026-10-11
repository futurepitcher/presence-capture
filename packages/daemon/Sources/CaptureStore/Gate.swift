import Foundation

/// What a sensor plugin may emit (ADR 0007), validated as packages/schema/cases/observations.json
/// says, and the gate every observation passes before it's written: excluded (R8), then
/// redacted, then appended, where the store seals it (R11). The same rules as the reference's
/// src/observations.js and src/gate.js.
public enum Observations {
    private static let iso = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"#)

    /// Nil when the header is valid; otherwise why not.
    public static func headerError(_ value: Any?) -> String? {
        guard let header = value as? [String: Any] else { return "not an object" }
        guard let name = header["sensor"] as? String,
              name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            return "sensor names are lower-case letters, digits and hyphens"
        }
        guard header["protocol"] as? String == "1" else { return "unknown protocol" }
        return nil
    }

    /// Nil when the observation is valid; otherwise why not.
    public static func error(_ value: Any?) -> String? {
        guard let o = value as? [String: Any] else { return "not an object" }
        guard let at = o["at"] as? String, iso.firstMatch(in: at, range: NSRange(at.startIndex..., in: at)) != nil,
              CaptureStore.date(at) != nil else { return "at must be an ISO 8601 UTC time" }
        let text = { (key: String) in o[key] as? String }
        let absentOr = { (key: String, allowed: Set<String>?) -> Bool in
            guard let value = o[key], !(value is NSNull) else { return true }
            guard let string = value as? String else { return false }
            return allowed.map { $0.contains(string) } ?? true
        }
        switch text("kind") {
        case "screen":
            guard text("app") != nil, text("window") != nil, text("text") != nil else { return "screen needs app, window and text" }
            guard absentOr("url", nil) else { return "url must be text" }
            guard absentOr("extraction", ["accessibility", "ocr"]) else { return "unknown extraction" }
            return nil
        case "activity":
            guard text("app") != nil, absentOr("window", nil) else { return "activity needs app" }
            guard let state = text("state"), ["active", "idle", "locked"].contains(state) else { return "unknown activity state" }
            return nil
        case "audio":
            guard let device = text("device"), ["input", "output"].contains(device), text("transcript") != nil else {
                return "audio needs device input or output, and transcript"
            }
            if let seconds = o["seconds"], !(seconds is NSNull), !(seconds is NSNumber) { return "seconds must be a number" }
            return nil
        default:
            return "unknown kind: \(text("kind") ?? "none")"
        }
    }
}

/// Puts observations through exclusion, redaction and sealing into a store. A sensor plugin's
/// captures all carry `source`, `sensor:<name>`, so one sensor's can be revoked at once.
public final class Gate: @unchecked Sendable {
    public struct Stats: Equatable, Sendable {
        public var appended = 0
        public var excluded = 0
        public var redacted = 0
        public var invalid = 0

        public init(appended: Int = 0, excluded: Int = 0, redacted: Int = 0, invalid: Int = 0) {
            (self.appended, self.excluded, self.redacted, self.invalid) = (appended, excluded, redacted, invalid)
        }
    }

    private let store: CaptureStore
    private let source: String?
    private let lock = NSLock()
    private var counts = Stats()

    public init(store: CaptureStore, source: String? = nil) {
        self.store = store
        self.source = source
    }

    public var stats: Stats { lock.withLock { counts } }

    public func takeStats() -> Stats {
        lock.withLock {
            defer { counts = Stats() }
            return counts
        }
    }

    /// One observation, as parsed from JSON, against the user's exclusion list.
    public func ingest(_ value: Any?, fragments: [String]) throws {
        guard Observations.error(value) == nil, let o = value as? [String: Any], let at = (o["at"] as? String).flatMap(CaptureStore.date) else {
            lock.withLock { counts.invalid += 1 }
            return
        }
        let text = { (key: String) in o[key] as? String }
        func clean(_ value: String) -> String {
            let out = Redact.redact(value)
            if out != value { lock.withLock { counts.redacted += 1 } }
            return out
        }
        func append(_ capture: NewCapture) throws -> String {
            let id = try store.append(capture)
            lock.withLock { counts.appended += 1 }
            return id
        }
        func json(_ object: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }

        let kind = text("kind")!
        if kind == "audio" {
            let device = text("device")!
            let segment = try append(NewCapture(capturedAt: at, captureType: "audio_segment", source: source ?? "ambient_audio", sourceApp: device))
            _ = try append(NewCapture(capturedAt: at, captureType: "audio_transcript", source: source ?? "ambient_audio", sourceApp: device,
                                      contentText: clean(text("transcript")!), extraction: "asr", derivedFrom: segment))
            return
        }

        let app = text("app")!
        let window = text("window") ?? ""
        // Exclusion first: nothing of an excluded window is written. Activity keeps its state alone.
        if Exclusion.isExcluded(app: app, window: window, fragments: fragments) {
            lock.withLock { counts.excluded += 1 }
            if kind == "activity" {
                _ = try append(NewCapture(capturedAt: at, captureType: "activity", source: source ?? "activity",
                                          contentText: json(["state": text("state")!, "excluded": true]), extraction: "none"))
            }
            return
        }
        if kind == "screen" {
            _ = try append(NewCapture(capturedAt: at, captureType: "screen_text", source: source ?? "screen", sourceApp: text("bundle") ?? app,
                                      sourceUrl: text("url"), contentText: clean(text("text")!), extraction: text("extraction") ?? "ocr"))
        } else {
            _ = try append(NewCapture(capturedAt: at, captureType: "activity", source: source ?? "activity", sourceApp: text("bundle") ?? app,
                                      contentText: json(["app": app, "window": clean(window), "state": text("state")!]), extraction: "none"))
        }
    }
}
