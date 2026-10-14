import Foundation

/// What is never captured (R8), decided before any bytes exist. The same lists and answers as
/// the reference (src/exclusion.js); packages/schema/cases/exclusion.json holds both to them.
public enum Exclusion {
    /// System UI that is never a memory: the lock screen, password and Touch ID prompts, notifications.
    public static let systemApps = ["usernotificationcenter", "securityagent", "coreautha", "loginwindow", "screensaverengine"]
    /// The app's own windows, so it never records itself.
    public static let selfWindows = ["presence capture"]

    /// The user's list: one fragment a line, "#" starts a comment, blank lines skipped, lower-cased.
    public static func parse(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            let kept = (line.range(of: "#").map { String(line[..<$0.lowerBound]) } ?? line)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return kept.isEmpty ? nil : kept
        }
    }

    /// The user's list at `path`. None yet is an empty one; one that exists but can't be read is
    /// nil, and nothing is captured while it is (taking it for empty would capture what it names).
    public static func load(_ path: String) -> [String]? {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func isExcluded(app: String, window: String, fragments: [String]) -> Bool {
        let app = app.lowercased()
        if systemApps.contains(app) { return true }
        let title = window.lowercased()
        return (selfWindows + fragments).contains { title.contains($0) || app.contains($0) }
    }
}

/// Since when the exclusion list has been readable, without a break (R8). What's heard is kept only
/// if it was said since then: speech from a stretch when the list couldn't be read never gets in,
/// however late its transcript arrives, or however hearing was started meanwhile.
public final class ReadableSince: @unchecked Sendable {
    private let lock = NSLock()
    private var since: Date?

    public init() {}

    /// The list was just read, or couldn't be.
    public func observe(_ readable: Bool, at now: Date = Date()) {
        lock.withLock { since = readable ? (since ?? now) : nil }
    }

    /// Whether what was said at `saidAt` may be kept.
    public func admits(_ saidAt: Date) -> Bool {
        lock.withLock { since.map { saidAt >= $0 } ?? false }
    }
}
