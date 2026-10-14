import CaptureStore
import Foundation

/// An MCP client Presence Capture can connect: given its own grant, and `pcap-mcp` in its config.
public enum Client: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case cursor

    public var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        }
    }

    /// What the person does for the client to start the server.
    public var afterward: String {
        switch self {
        case .claudeCode: return "New Claude Code sessions have it."
        case .claudeDesktop: return "Quit Claude Desktop completely and open it again to load it."
        case .cursor: return "Cursor loads it from Settings → MCP (reload the window if it doesn't appear)."
        }
    }
}

/// The name the server has in every client's config.
public let serverName = "presence-capture"

/// The server a client is given: `pcap-mcp` by its absolute path, reading through its grant, from
/// the store the grant is in, named by its absolute path: an agent's environment is its own, so
/// nothing is left for pcap-mcp to work out.
public struct ServerEntry: Equatable, Sendable {
    public var command: String
    public var args: [String]

    /// `store` absolute; `keyFile`, absolute, only for a store whose key isn't the Keychain's.
    public init(pcapMCP: String, grantId: String, store: String, keyFile: String? = nil) {
        command = pcapMCP
        args = ["--grant", grantId, "--store", store] + (keyFile.map { ["--master-key-file", $0] } ?? [])
    }

    var grantId: String { Connector.option("--grant", args) ?? "" }

    /// As the client's config holds it. Claude Desktop's documented form has no `type`.
    func json(for client: Client) -> [String: Any] {
        var entry: [String: Any] = ["command": command, "args": args]
        if client != .claudeDesktop { entry["type"] = "stdio" }
        return entry
    }
}

public enum ConnectError: Error, CustomStringConvertible, Equatable {
    /// The config exists but can't be read, or isn't a JSON object this can add to: it's left as it is.
    case unreadable(path: String, why: String)
    /// The config changed after the change to it was worked out: nothing was written.
    case changed(path: String)
    /// Another connection held the config for longer than `Connector.lockWait`: nothing was written.
    case busy(path: String)
    /// Something about this Mac means the client's config can't be found for sure: nothing was done.
    case unsupported(String)
    /// Claude Code's own command isn't installed where it can be found.
    case claudeNotFound
    /// `claude` refused; what it said.
    case claudeFailed(command: String, output: String)
    /// The entry that was there was removed, and the new one couldn't be added: whether the old one
    /// was put back, and where the config was copied before.
    case claudeAddFailed(command: String, output: String, restored: Bool, backup: String?)
    /// A grant that should have been withdrawn couldn't be: it can still read until it's revoked,
    /// with the command that does it.
    case grantLeft(grantId: String, after: String, why: String, revoke: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let why): return "\(path) can't be added to (\(why)); it's left as it is"
        case .changed(let path): return "\(path) changed while the change to it was being shown; nothing was written. Connect again to see it as it is now"
        case .busy(let path): return "another connection is changing \(path); nothing was written. Try again in a moment"
        case .unsupported(let why): return why
        case .claudeNotFound: return "Claude Code's `claude` command wasn't found. Install Claude Code, then connect again"
        case .claudeFailed(let command, let output): return "`\(command)` failed:\n\(output)"
        case .claudeAddFailed(let command, let output, let restored, let backup):
            return "`\(command)` failed:\n\(output)\n" + (restored
                ? "The connection that was there is put back as it was."
                : "The connection that was there couldn't be put back\(backup.map { "; Claude Code's config as it was is in \($0)" } ?? "").")
        case .grantLeft(let grantId, let after, let why, let revoke):
            return "\(after); and its grant \(grantId) couldn't be withdrawn (\(why)). Revoke it:\n  \(revoke)"
        }
    }
}

/// A change to one client's config, worked out and shown before it's made.
public struct ConnectPlan: Sendable {
    public let client: Client
    /// The grant the new entry reads through.
    public let grantId: String
    /// The file the change lands in.
    public let file: URL
    /// What changes, a line at a time: "- " removed, "+ " added, "  " unchanged context.
    public let diff: String
    /// The grant the entry this replaces reads through, revoked once the change is made.
    public let replacing: String?
    /// That entry's arguments: which store its grant is in.
    let replacedArgs: [String]
    /// Anything that changes what the client does with it.
    public let notes: [String]
    /// What the change was worked out from: the file's bytes, or for Claude Code its entry. It's
    /// checked again before writing, so a change made meanwhile is never written over unseen.
    let before: Data?
    let write: Write

    enum Write: Sendable {
        /// The file's whole new text.
        case file(String)
        /// `claude mcp add-json` with these arguments, after removing the entry there (`before`).
        case claude(URL, add: [String])
    }
}

/// Where a client's config is, and how to change it. Everything it needs from this Mac is given, so
/// a test can point it at a folder of its own.
public struct Connector: Sendable {
    public var home: URL
    /// Claude Code's `claude` command, when it's installed.
    public var claude: URL?
    public var now: @Sendable () -> Date
    /// The environment `claude` runs with, and whose settings say where configs are.
    public var environment: [String: String]

    /// How long to wait for another connection's turn, and for `claude` to finish, before giving up:
    /// a connection never holds the app (or a terminal) indefinitely.
    public static let lockWait: TimeInterval = 10
    public static let claudeWait: TimeInterval = 60

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL? = nil, claude: URL?? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let home = home ?? Connector.home(environment: environment)
        self.environment = environment
        self.home = home
        self.claude = claude ?? Connector.findClaude(environment: environment, home: home)
        self.now = now
    }

    /// What has to hold before anything is issued or written for `client`.
    public func check(_ client: Client) throws {
        guard client == .claudeCode else { return }
        // It moves Claude Code's settings to a place of its own, which this can't be sure of finding.
        if environment["CLAUDE_CONFIG_DIR"] != nil {
            throw ConnectError.unsupported("CLAUDE_CONFIG_DIR is set, so Claude Code keeps its settings where this can't be sure of finding them. Unset it, or add the entry by hand (packages/daemon/README.md)")
        }
        if claude == nil { throw ConnectError.claudeNotFound }
    }

    public func file(for client: Client) -> URL {
        switch client {
        case .claudeCode: return home.appendingPathComponent(".claude.json")
        case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        }
    }

    /// The change, worked out but not made: the client's config is read, never written.
    public func plan(_ client: Client, entry: ServerEntry) throws -> ConnectPlan {
        try check(client)
        let file = file(for: client)
        let bytes = try read(file)
        let root = try Self.root(bytes, file)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let old = servers[serverName] as? [String: Any]
        let replacedArgs = old?["args"] as? [String] ?? []
        let replacing = Self.option("--grant", replacedArgs)
        let new = entry.json(for: client)

        if client == .claudeCode {
            // Changed through `claude mcp`, Claude Code's supported way: its file holds its own state too.
            let add = ["mcp", "add-json", serverName, PrettyJSON.compact(new), "--scope", "user"]
            guard let claude else { throw ConnectError.claudeNotFound }
            var notes: [String] = []
            for (project, settings) in (root["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                if ((settings as? [String: Any])?["mcpServers"] as? [String: Any])?[serverName] != nil {
                    notes.append("In \(project), its own \(serverName) entry is used instead of this one.")
                }
            }
            let before = old.map { PrettyJSON.text($0) } ?? ""
            return ConnectPlan(client: client, grantId: entry.grantId, file: file, diff: LineDiff.render(before, PrettyJSON.text(new)),
                               replacing: replacing, replacedArgs: replacedArgs, notes: notes, before: old.map { Data(PrettyJSON.compact($0).utf8) },
                               write: .claude(claude, add: add))
        }

        servers[serverName] = new
        var changed = root
        changed["mcpServers"] = servers
        let after = PrettyJSON.text(changed)
        return ConnectPlan(client: client, grantId: entry.grantId, file: file, diff: LineDiff.render(bytes.map { String(decoding: $0, as: UTF8.self) } ?? "", after),
                           replacing: replacing, replacedArgs: replacedArgs, notes: [], before: bytes, write: .file(after))
    }

    /// A config's bytes; nil only when there's no file. A file that's there but can't be read, or
    /// isn't UTF-8 text, is refused, never taken for an empty one.
    private func read(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: file) } catch { throw ConnectError.unreadable(path: file.path, why: "it can't be read") }
        guard String(data: bytes, encoding: .utf8) != nil else { throw ConnectError.unreadable(path: file.path, why: "it isn't UTF-8 text") }
        return bytes
    }

    /// The config's top level: empty for no file or an empty one; an error for anything else that
    /// isn't a JSON object with an object of servers.
    private static func root(_ bytes: Data?, _ file: URL) throws -> [String: Any] {
        guard let bytes, !String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ConnectError.unreadable(path: file.path, why: "it isn't a JSON object")
        }
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            throw ConnectError.unreadable(path: file.path, why: "its mcpServers isn't an object")
        }
        return root
    }

    /// Makes the change, if the config is still as it was when the change was worked out; otherwise
    /// it throws `changed` and writes nothing. The config is copied aside first, beside itself; the
    /// copy's location is returned (nil when there was no config yet). A file is replaced whole,
    /// never left half written, with the permissions it had. Two connections take turns (an advisory
    /// lock on the config's folder), so the second sees the first's change.
    @discardableResult
    public func apply(_ plan: ConnectPlan) throws -> URL? {
        try locked(plan.file.deletingLastPathComponent()) {
            let now = try read(plan.file)
            switch plan.write {
            case .file: guard now == plan.before else { throw ConnectError.changed(path: plan.file.path) }
            case .claude:
                let entry = (try Self.root(now, plan.file)["mcpServers"] as? [String: Any])?[serverName] as? [String: Any]
                guard entry.map({ Data(PrettyJSON.compact($0).utf8) }) == plan.before else { throw ConnectError.changed(path: plan.file.path) }
            }
            let backup = try copyAside(plan.file)
            switch plan.write {
            case .file(let text):
                let manager = FileManager.default
                let permissions = (try? manager.attributesOfItem(atPath: plan.file.path))?[.posixPermissions]
                try Data(text.utf8).write(to: plan.file, options: .atomic)
                if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: plan.file.path) }
            case .claude(let claude, let add):
                guard let previous = plan.before.map({ String(decoding: $0, as: UTF8.self) }) else {
                    try run(claude, add)
                    break
                }
                try run(claude, ["mcp", "remove", serverName, "--scope", "user"])
                do {
                    try run(claude, add)
                } catch {
                    // Removed, and not replaced, however it failed: what was there goes back.
                    let restored = (try? run(claude, ["mcp", "add-json", serverName, previous, "--scope", "user"])) != nil
                    let (command, output): (String, String)
                    if case ConnectError.claudeFailed(let c, let o) = error { (command, output) = (c, o) } else {
                        (command, output) = ((["claude"] + add).map(Self.shellQuoted).joined(separator: " "), "\(error)")
                    }
                    throw ConnectError.claudeAddFailed(command: command, output: output, restored: restored, backup: backup?.path)
                }
            }
            return backup
        }
    }

    private func copyAside(_ file: URL) throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return nil }
        let stamp = ISO8601DateFormatter.string(from: now(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let base = "\(file.lastPathComponent).presence-capture-backup-\(stamp)"
        var copy = file.deletingLastPathComponent().appendingPathComponent(base)
        var n = 1
        while manager.fileExists(atPath: copy.path) {
            n += 1
            copy = file.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)")
        }
        try manager.copyItem(at: file, to: copy)
        return copy
    }

    /// Runs `body` holding an advisory lock on `folder`, which connections take and the clients
    /// don't: `pcap connect` and the menu's Connect an Agent… take turns, waiting at most `lockWait`.
    private func locked<T>(_ folder: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_RDONLY)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(Self.lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw ConnectError.busy(path: folder.path) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func run(_ claude: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        // An app's PATH is short; `claude` may be a script that needs node beside it.
        var environment = self.environment
        let path = [claude.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
        environment["PATH"] = path.joined(separator: ":")
        environment["HOME"] = home.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        // Read as it comes, so a chatty `claude` never blocks on a full pipe.
        var said = Data()
        let reading = DispatchQueue(label: "presence.connect.claude")
        let done = DispatchSemaphore(value: 0)
        reading.async {
            said = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let command = (["claude"] + arguments).map(Self.shellQuoted).joined(separator: " ")
        guard ended.wait(timeout: .now() + Self.claudeWait) == .success else {
            process.terminate()
            throw ConnectError.claudeFailed(command: command, output: "it didn't finish within \(Int(Self.claudeWait)) seconds")
        }
        done.wait()
        guard process.terminationStatus == 0 else {
            throw ConnectError.claudeFailed(command: command, output: String(decoding: said, as: UTF8.self))
        }
    }

    /// The home folder the clients find their configs in: $HOME, as they read it.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    }

    /// `claude` on PATH, or where its installers put it (an app launched from the Dock has a short PATH).
    public static func findClaude(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = Connector.home()) -> URL? {
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = [".local/bin", ".claude/local", ".npm-global/bin"].map { home.appendingPathComponent($0).path } + ["/opt/homebrew/bin", "/usr/local/bin"]
        return (onPath + usual).lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// An option's value in an entry's arguments.
    static func option(_ name: String, _ args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// The command that revokes the grant an entry's arguments name, in the store they name.
    public static func revokeCommand(_ args: [String]) -> String {
        var words = ["pcap", "grant", "revoke", option("--grant", args) ?? "<grant_id>"]
        if let store = option("--store", args) { words += ["--store", store] }
        if let key = option("--master-key-file", args) { words += ["--master-key-file", key] }
        return words.map(shellQuoted).joined(separator: " ")
    }

    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }

    /// A word as a shell reads it back, for a command shown to the person to run.
    static func shellQuoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@".contains($0) } ? word : "'\(word.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// A client connected: the grant it reads through, where its old config was copied, and the grant
/// of the entry it replaced: revoked, or, if that failed, still active and to be revoked by hand.
public struct Connection: Sendable {
    public let grantId: String
    public let expiresAt: Date
    public let backup: URL?
    public let revoked: String?
    /// The replaced entry's grant, which couldn't be revoked: why, and the command that revokes it.
    public let stillActive: (grantId: String, why: String, revoke: String)?
}

extension Connector {
    /// What `pcap connect` and the menu's Connect an Agent… do, in order. A grant for the client is
    /// issued; the change to its config is worked out and given to `confirm`, which shows it and asks;
    /// then it's made, and the grant of the entry it replaced is revoked. Nil when the person
    /// declines. A grant whose config wasn't written (declined, or the write failed) is withdrawn
    /// again; one that can't be is an error naming it, never left quietly. A config that changed
    /// while the change was shown is worked out and shown again, up to three times.
    ///
    /// `entry` makes the server entry for the grant.
    public func connect(_ client: Client, store: CaptureStore, grant: NewGrant, entry: (String) -> ServerEntry,
                        confirm: (ConnectPlan) throws -> Bool) throws -> Connection? {
        // Before a grant is issued: one issued for nothing would only be withdrawn again.
        try check(client)
        let grantId = try store.issueGrant(grant)
        let new = entry(grantId)
        func withdraw(after reason: String) throws {
            do { try store.revokeGrant(grantId) } catch {
                throw ConnectError.grantLeft(grantId: grantId, after: reason, why: "\(error)", revoke: Self.revokeCommand(new.args))
            }
        }
        let made: (plan: ConnectPlan, backup: URL?)?
        do {
            made = try confirmAndApply(client, entry: new, confirm: confirm)
        } catch {
            try withdraw(after: "\(error)")
            throw error
        }
        guard let made else {
            try withdraw(after: "Nothing was written")
            return nil
        }
        // The config now names the new grant; the old one reads for nothing, so it goes. It's revoked
        // in its own store: this one, unless the entry it was in named another.
        var revoked: String?
        var stillActive: (grantId: String, why: String, revoke: String)?
        if let old = made.plan.replacing, old != grantId {
            let revoke = Self.revokeCommand(made.plan.replacedArgs)
            let here = Self.option("--store", new.args).map(Self.standardized)
            let there = Self.standardized(Self.option("--store", made.plan.replacedArgs) ?? CaptureStore.defaultHome + "/store.sqlite")
            if here != there {
                stillActive = (old, "it's in another store, \(there)", revoke)
            } else {
                do {
                    if try store.revokeGrant(old) { revoked = old }
                    else if try store.grants().first(where: { $0.grantId == old }) == nil { stillActive = (old, "it isn't in this store", revoke) }
                } catch {
                    stillActive = (old, "\(error)", revoke)
                }
            }
        }
        return Connection(grantId: grantId, expiresAt: grant.expiresAt, backup: made.backup, revoked: revoked, stillActive: stillActive)
    }

    private func confirmAndApply(_ client: Client, entry: ServerEntry, confirm: (ConnectPlan) throws -> Bool) throws -> (plan: ConnectPlan, backup: URL?)? {
        var attempt = 0
        while true {
            attempt += 1
            let plan = try self.plan(client, entry: entry)
            guard try confirm(plan) else { return nil }
            do {
                return (plan, try apply(plan))
            } catch ConnectError.changed(let path) {
                if attempt == 3 { throw ConnectError.changed(path: path) }
            }
        }
    }
}

/// JSON as people read it: two-space indents, keys sorted, and each scalar as JSONSerialization
/// writes it, so numbers and strings come back exactly as they were read.
enum PrettyJSON {
    static func text(_ value: Any) -> String { write(value, indent: "") + "\n" }

    static func compact(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    private static func write(_ value: Any, indent: String) -> String {
        let inner = indent + "  "
        if let object = value as? [String: Any] {
            if object.isEmpty { return "{}" }
            let members = object.keys.sorted().map { "\(inner)\(scalar($0)): \(write(object[$0]!, indent: inner))" }
            return "{\n\(members.joined(separator: ",\n"))\n\(indent)}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            return "[\n\(array.map { inner + write($0, indent: inner) }.joined(separator: ",\n"))\n\(indent)]"
        }
        return scalar(value)
    }

    private static func scalar(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8),
               as: UTF8.self)
    }
}

/// The lines that change between two texts, with two lines of context around each change.
enum LineDiff {
    static func render(_ before: String, _ after: String, context: Int = 2) -> String {
        let old = lines(before), new = lines(after)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk both, in order: a removed line, then an added one, else the same line in each.
        var marked: [(mark: Character, line: String)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { marked.append(("-", old[i])); i += 1 }
            else if j < new.count, inserted.contains(j) { marked.append(("+", new[j])); j += 1 }
            else { marked.append((" ", new[j])); i += 1; j += 1 }
        }
        let changed = marked.indices.filter { marked[$0].mark != " " }
        let shown = Set(changed.flatMap { max(0, $0 - context)...min(marked.count - 1, $0 + context) })
        var out: [String] = []
        var last = -1
        for index in marked.indices where shown.contains(index) {
            if last >= 0, index > last + 1 { out.append("  …") }
            out.append("\(marked[index].mark) \(marked[index].line)")
            last = index
        }
        return out.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : Array(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast(text.hasSuffix("\n") ? 1 : 0))
    }
}
