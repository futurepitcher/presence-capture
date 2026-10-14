import CaptureConnect
import CaptureStore
import CryptoKit
import Foundation

// pcap: Presence Capture from the command line. A writer to the store, as the app is, and in its
// bundle, so the Keychain item the app makes trusts it (MasterKeyItem v2). What it shows of what
// agents read is counts and metadata, never content.

let usage = """
    pcap: Presence Capture from the command line

      pcap connect <claude-code|claude-desktop|cursor> [--types …] [--levels …] [--days 30] [--yes] [--dry-run]
          give an agent its own grant and add pcap-mcp to its MCP config: the change is shown,
          and asked about, before it's made, and the config is copied aside first
      pcap grant add <client> [--types t,…] [--levels l,…] [--days 30]
      pcap grant list [--all]
      pcap grant revoke <grant_id>
      pcap egress [--days 7]       what each agent was given: counts, never content
      pcap forget <15m|1h|…>       revoke the stretch just past, and erase it from disk
      pcap check                   the store's key, structure, egress log and erasures

      --store <path>, --master-key-file <path>: another store; by default, the app's, with its key
      from the Keychain. --pcap-mcp <path>: the server `connect` names; by default, the one beside pcap.

    """

struct Failure: Error {
    let message: String
    let status: Int32
    init(_ message: String, status: Int32 = 2) {
        self.message = message
        self.status = status
    }
}

/// The words, and the options: `--name value`, or a flag on its own.
struct Arguments {
    static let flags: Set = ["yes", "dry-run", "all", "help"]
    var words: [String] = []
    var options: [String: String] = [:]
    var set: Set<String> = []

    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        while let word = rest.popFirst() {
            guard word.hasPrefix("--") else { words.append(word); continue }
            let name = String(word.dropFirst(2))
            if Self.flags.contains(name) { set.insert(name); continue }
            guard let value = rest.popFirst() else { throw Failure("--\(name) needs a value") }
            options[name] = value
        }
    }

    /// Refuses, before anything is opened or changed, an option or flag `command` doesn't take, and
    /// more or fewer words than it does: a misspelled `--type` never quietly grants every type, and
    /// `forget 15m --dry-run` never forgets.
    func check(_ command: String, words count: Int, options allowed: Set<String> = [], flags: Set<String> = []) throws {
        let store: Set = ["store", "master-key-file"]
        if let unknown = options.keys.sorted().first(where: { !allowed.union(store).contains($0) }) { throw Failure("\(command) doesn't take --\(unknown)") }
        if let unknown = set.sorted().first(where: { !flags.contains($0) }) { throw Failure("\(command) doesn't take --\(unknown)") }
        if words.count != count { throw Failure("\(command): \(words.count < count ? "something's missing" : "too many words: \(words.dropFirst(count).joined(separator: " "))") (pcap help)") }
    }

    func list(_ name: String) -> [String]? {
        options[name].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    func days(_ name: String = "days", default value: Int) throws -> Int {
        guard let text = options[name] else { return value }
        guard let days = Int(text), (1...3650).contains(days) else { throw Failure("--\(name) must be a whole number of days, 1 to 3650") }
        return days
    }
}

let captureTypes = ["screen_frame", "screen_text", "audio_segment", "audio_transcript", "audio_alignment", "activity"]
let grantableLevels = ["standard", "sensitive", "excluded"]

/// The grant the options describe: standard captures of every type for 30 days, unless they say
/// otherwise. `sacred_mode` is never grantable (the schema refuses it).
func grant(for clientId: String, _ arguments: Arguments) throws -> NewGrant {
    var grant = NewGrant(clientId: clientId, expiresAt: Date().addingTimeInterval(Double(try arguments.days(default: 30)) * 86_400))
    if let types = arguments.list("types") {
        if let unknown = types.first(where: { !captureTypes.contains($0) }) { throw Failure("no capture type \(unknown): \(captureTypes.joined(separator: ", "))") }
        grant.captureTypes = types
    }
    if let levels = arguments.list("levels") {
        if let refused = levels.first(where: { !grantableLevels.contains($0) }) {
            throw Failure("\(refused) can't be granted: \(grantableLevels.joined(separator: ", "))\(refused == "sacred_mode" ? " (sacred_mode never leaves this Mac)" : "")")
        }
        grant.privacyLevels = levels
    }
    return grant
}

func describe(_ grant: NewGrant) -> String {
    let types = grant.captureTypes == ["*"] ? "every type" : grant.captureTypes.joined(separator: ", ")
    return "\(grant.privacyLevels.joined(separator: ", ")) captures of \(types), for \(grant.maxRowsPerQuery) rows a read at most, until \(day(grant.expiresAt))"
}

func day(_ date: Date) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd HH:mm"
    return format.string(from: date)
}

/// A path as given, made absolute against where pcap was run.
func absolute(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

/// The app's store, or the one --store names: absolute, whichever it is.
func storePath(_ arguments: Arguments) -> String {
    absolute(arguments.options["store"] ?? CaptureStore.home + "/store.sqlite")
}

/// The app's store, or the one --store names, opened as a writer. A store that isn't there isn't
/// made: that's the app's job, at its first launch.
func openStore(_ arguments: Arguments) throws -> CaptureStore {
    let path = storePath(arguments)
    guard FileManager.default.fileExists(atPath: path) else { throw Failure("there's no store at \(path): open Presence Capture once to make it") }
    let key: Data
    do {
        key = try MasterKeyItem.load(keyFile: arguments.options["master-key-file"].map(absolute), bundleIdentifier: Bundle.main.bundleIdentifier)
    } catch {
        throw Failure("\(error)")
    }
    do {
        return try CaptureStore(path: path, masterKey: SymmetricKey(data: key))
    } catch {
        throw Failure("the store can't be opened: \(error)")
    }
}

/// `pcap-mcp` beside this program (in the app's bundle, Contents/MacOS), followed through a link
/// such as Homebrew's, or the one --pcap-mcp names.
func pcapMCP(_ arguments: Arguments) throws -> String {
    let path = arguments.options["pcap-mcp"].map(absolute)
        ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("pcap-mcp").path
    guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure("pcap-mcp isn't at \(path)") }
    return path
}

/// The server entry for a grant: the store by its absolute path, and the key file when one was
/// given, since pcap-mcp, started by the agent in its own environment, can't work either out.
func entry(_ arguments: Arguments, server: String) -> (String) -> ServerEntry {
    let store = storePath(arguments)
    let keyFile = arguments.options["master-key-file"].map(absolute)
    return { ServerEntry(pcapMCP: server, grantId: $0, store: store, keyFile: keyFile) }
}

/// This program's absolute path, followed through a link, for commands it shows.
func thisProgram() -> String {
    (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
}

func ask(_ question: String) -> Bool {
    print(question, terminator: " ")
    return ["y", "yes"].contains(readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
}

// MARK: Commands

func connect(_ arguments: Arguments) throws {
    try arguments.check("connect", words: 2, options: ["types", "levels", "days", "pcap-mcp"], flags: ["yes", "dry-run"])
    guard let name = arguments.words.dropFirst().first, let client = Client(rawValue: name) else {
        throw Failure("connect which? \(Client.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    let connector = Connector(pcap: thisProgram())
    let server = try pcapMCP(arguments)
    let entry = entry(arguments, server: server)
    let grant = try grant(for: client.rawValue, arguments)
    let show = { (plan: ConnectPlan) in
        print("Connect \(client.name) to Presence Capture\n")
        print("  Grant \(plan.grantId) for \(client.rawValue): \(describe(grant)).")
        print("  Config: \(plan.file.path)\(client == .claudeCode ? " (user scope, written by `claude mcp`)" : "")")
        if FileManager.default.fileExists(atPath: plan.file.path) { print("  It's copied aside first, beside itself.") }
        if let old = plan.replacing { print("  It replaces the entry reading through \(old), which is revoked.") }
        for note in plan.notes { print("  \(note)") }
        print("\n\(plan.diff)\n")
    }
    if arguments.set.contains("dry-run") {
        show(try connector.plan(client, entry: entry("grn_(issued when it's written)")))
        return
    }
    let interactive = isatty(STDIN_FILENO) == 1
    guard arguments.set.contains("yes") || interactive else {
        throw Failure("connect asks before it writes; with no one to ask, pass --yes (or --dry-run to see the change)")
    }
    let store = try openStore(arguments)
    defer { store.close() }
    let connection = try connector.connect(client, store: store, grant: grant, entry: entry) { plan in
        show(plan)
        return arguments.set.contains("yes") || ask("Write this? [y/N]")
    }
    guard let connection else {
        print("Nothing was written; the grant was withdrawn.")
        return
    }
    print("Connected. \(client.name) reads Presence Capture through \(connection.grantId) until \(day(connection.expiresAt)).")
    if let backup = connection.backup { print("The config as it was: \(backup.path)") }
    if let revoked = connection.revoked { print("The grant it replaced, \(revoked), is revoked.") }
    print(client.afterward)
    if let left = connection.stillActive {
        throw Failure("but the grant it replaced, \(left.grantId), couldn't be revoked (\(left.why)), and can still read. Revoke it:\n  \(left.revoke)", status: 1)
    }
}

func grantCommand(_ arguments: Arguments) throws {
    switch arguments.words.dropFirst().first {
    case "add":
        try arguments.check("grant add", words: 3, options: ["types", "levels", "days", "pcap-mcp"])
        guard let clientId = arguments.words.dropFirst(2).first, !clientId.isEmpty else { throw Failure("grant add needs a client name, as the agent will be known") }
        let grant = try grant(for: clientId, arguments)
        let store = try openStore(arguments)
        defer { store.close() }
        let grantId = try store.issueGrant(grant)
        let server = entry(arguments, server: (try? pcapMCP(arguments)) ?? "pcap-mcp")(grantId)
        let quoted = ([server.command] + server.args).map(Connector.shellQuoted).joined(separator: " ")
        print("\(grantId)\n  \(clientId): \(describe(grant)).\n  Its server: \(quoted)")
    case "list":
        try arguments.check("grant list", words: 2, flags: ["all"])
        let store = try openStore(arguments)
        defer { store.close() }
        let now = Date()
        let grants = try store.grants().filter { arguments.set.contains("all") || $0.isActive(at: now) }
        if grants.isEmpty { print(arguments.set.contains("all") ? "No grants." : "No active grants (--all for every grant)."); return }
        for g in grants {
            let state = g.revokedAt.map { "revoked \(day($0))" } ?? (g.expiresAt > now ? "until \(day(g.expiresAt))" : "expired \(day(g.expiresAt))")
            let types = g.captureTypes == ["*"] ? "every type" : g.captureTypes.joined(separator: ",")
            print("\(g.grantId)  \(g.clientId)  \(state)  \(g.privacyLevels.joined(separator: ",")) · \(types) · \(g.maxRowsPerQuery) rows a read")
        }
    case "revoke":
        try arguments.check("grant revoke", words: 3)
        guard let grantId = arguments.words.dropFirst(2).first else { throw Failure("grant revoke needs a grant id (pcap grant list)") }
        let store = try openStore(arguments)
        defer { store.close() }
        guard try store.revokeGrant(grantId) else { throw Failure("no active grant \(grantId)", status: 1) }
        print("Revoked \(grantId): every read under it is refused from now on.")
    default:
        throw Failure("grant add, grant list or grant revoke")
    }
}

func egress(_ arguments: Arguments) throws {
    try arguments.check("egress", words: 1, options: ["days"])
    let days = try arguments.days(default: 7)
    let store = try openStore(arguments)
    defer { store.close() }
    let lines = try store.egress(since: Date().addingTimeInterval(-Double(days) * 86_400))
    if lines.isEmpty { print("No agent has read anything in the last \(days) days."); return }
    var shown: String?
    for line in lines {
        if line.day != shown { print(line.day); shown = line.day }
        let types = line.types.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let what = line.tool == "index" ? "read into its search index, in pcap-mcp's memory on this Mac" : types
        print("  \(line.clientId)  \(line.tool)  \(line.reads) \(line.reads == 1 ? "read" : "reads"), \(line.rows) rows  \(what)")
    }
}

func forget(_ arguments: Arguments) throws {
    try arguments.check("forget", words: 2)
    guard let span = arguments.words.dropFirst().first, let unit = span.last, "mh".contains(unit),
          let count = Int(span.dropLast()), count > 0, count <= (unit == "m" ? 1440 : 24) else {
        throw Failure("forget how long? 15m, 1h, …: minutes or hours, up to a day")
    }
    let minutes = unit == "m" ? count : count * 60
    let label = "\(count) \(unit == "m" ? "minute" : "hour")\(count == 1 ? "" : "s")"
    let store = try openStore(arguments)
    defer { store.close() }
    let now = Date()
    let result = try store.revoke(scopeKind: "time_range",
                                  scopeValue: "\(CaptureStore.iso(now.addingTimeInterval(-Double(minutes) * 60)))/\(CaptureStore.iso(now))",
                                  reason: "forget \(minutes)m")
    let captures = "\(result.revokedCaptureIds.count) \(result.revokedCaptureIds.count == 1 ? "capture" : "captures")"
    if let error = result.erasureError {
        print("Forgot the last \(label): \(captures) revoked, and no one can read them.")
        throw Failure("erasing them from disk failed (\(error)). The erasure stays pending, and is tried again at the app's next tick or the next pcap command", status: 1)
    }
    if result.erasedOnDisk {
        print("Forgot the last \(label): \(captures) revoked and erased from disk.")
    } else {
        print("Forgot the last \(label): \(captures) revoked, and no one can read them; on-disk erasure pending, while a reader holds the store's log. It finishes when the reader lets go: at the app's next tick, or the next pcap command.")
    }
}

func check(_ arguments: Arguments) throws {
    try arguments.check("check", words: 1)
    let store = try openStore(arguments)
    defer { store.close() }
    var healthy = true
    let counts = try store.counts()
    print("store: \(counts.captures) captures, \(counts.revoked) revoked")
    print("key: this store's (checked as it opened)")
    let structure = try store.quickCheck()
    healthy = healthy && structure == "ok"
    print("structure: \(structure)")
    let chain = try store.verifyEgressChain()
    healthy = healthy && chain.ok
    print(chain.ok ? "egress log: \(chain.records) records, chain verifies" : "egress log: BROKEN at record \(chain.brokenAt ?? 0) (\(chain.reason ?? "?")): it was changed after it was written")
    let pending = !(try store.finishErasure())
    print(pending ? "erasure: pending, while a reader holds the store's log" : "erasure: complete")
    print("grants: \(try store.grants().filter { $0.isActive() }.count) active")
    if !healthy { throw Failure("the store failed its check", status: 1) }
}

// MARK: Main

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    switch arguments.words.first {
    case "connect": try connect(arguments)
    case "grant": try grantCommand(arguments)
    case "egress": try egress(arguments)
    case "forget": try forget(arguments)
    case "check": try check(arguments)
    case nil where arguments.set.contains("help"), "help": print(usage, terminator: "")
    default:
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
} catch let failure as Failure {
    FileHandle.standardError.write(Data("pcap: \(failure.message)\n".utf8))
    exit(failure.status)
} catch {
    FileHandle.standardError.write(Data("pcap: \(error)\n".utf8))
    exit(2)
}
