@testable import CaptureStore
import Foundation
import XCTest
@testable import CaptureConnect

/// Connecting an agent, against a home folder of the test's own: the person's real configs, and
/// their real `claude`, are never touched.
final class ConnectTests: XCTestCase {
    private var home: URL!
    private let server = "/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func connector(claude: URL? = nil) -> Connector {
        Connector(home: home, claude: claude, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private func write(_ text: String, to client: Client, permissions: Int = 0o600) throws -> URL {
        let file = connector().file(for: client)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        return file
    }

    private func json(_ file: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    /// A stand-in for Claude Code's `claude`: it notes each command it's given, and fails when told to.
    private func fakeClaude(failing: Bool = false, failingOn: String? = nil) throws -> (claude: URL, log: URL) {
        let bin = home.appendingPathComponent("fake bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("claude.log")
        let claude = bin.appendingPathComponent("claude")
        try Data("""
            #!/bin/sh
            for a in "$@"; do printf '%s\\n' "$a" >> '\(log.path)'; done
            printf -- '--\\n' >> '\(log.path)'
            \(failingOn.map { "case \"$*\" in *\($0)*) echo 'refused' >&2; exit 1;; esac" } ?? "")
            \(failing ? "echo 'refused' >&2; exit 1" : "exit 0")

            """.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return (claude, log)
    }

    private func commands(_ log: URL) throws -> [[String]] {
        try String(contentsOf: log, encoding: .utf8).components(separatedBy: "--\n").dropLast()
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
    }

    // MARK: Files: Claude Desktop and Cursor

    func testClaudeDesktopKeepsEverythingElseAndIsCopiedAsideFirst() throws {
        let original = """
            {"mcpServers": {"other": {"command": "/usr/bin/other", "args": ["--x"]}}, "preferences": {"theme": "dark", "ratio": 1.5, "on": true}}
            """
        let file = try write(original, to: .claudeDesktop)
        let plan = try connector().plan(.claudeDesktop, entry: ServerEntry(pcapMCP: server, grantId: "grn_new"))
        XCTAssertNil(plan.replacing)
        XCTAssertTrue(plan.diff.contains("+     \"presence-capture\": {"), plan.diff)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original, "planning wrote the config")

        let backup = try XCTUnwrap(try connector().apply(plan))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("claude_desktop_config.json.presence-capture-backup-"))
        let after = try json(file)
        let servers = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: Any])?["args"] as? [String], ["--x"], "another server was changed")
        let entry = try XCTUnwrap(servers["presence-capture"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, server, "the path with spaces was changed")
        XCTAssertEqual(entry["args"] as? [String], ["--grant", "grn_new"])
        XCTAssertNil(entry["type"], "Claude Desktop's documented entry has no type")
        let preferences = try XCTUnwrap(after["preferences"] as? [String: Any])
        XCTAssertEqual(preferences["ratio"] as? Double, 1.5)
        XCTAssertEqual(preferences["on"] as? Bool, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int, 0o600,
                       "the config's permissions were loosened")
    }

    func testCursorWithNoConfigYetGetsOneAndNoBackup() throws {
        let plan = try connector().plan(.cursor, entry: ServerEntry(pcapMCP: server, grantId: "grn_new"))
        XCTAssertNil(try connector().apply(plan))
        let entry = try XCTUnwrap((try json(connector().file(for: .cursor))["mcpServers"] as? [String: Any])?["presence-capture"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "stdio")
        XCTAssertEqual(entry["command"] as? String, server)
    }

    func testAnEntryAlreadyThereIsReplacedAndItsGrantNamed() throws {
        _ = try write(#"{"mcpServers": {"presence-capture": {"command": "/old/pcap-mcp", "args": ["--grant", "grn_old"]}}}"#, to: .cursor)
        let plan = try connector().plan(.cursor, entry: ServerEntry(pcapMCP: server, grantId: "grn_new"))
        XCTAssertEqual(plan.replacing, "grn_old")
        XCTAssertTrue(plan.diff.contains("-") && plan.diff.contains("grn_old") && plan.diff.contains("+") && plan.diff.contains("grn_new"), plan.diff)
    }

    func testAConfigThatIsntAJSONObjectIsLeftAlone() throws {
        for text in ["{ not json", "[1, 2]", #"{"mcpServers": ["a list"]}"#] {
            let file = try write(text, to: .claudeDesktop)
            XCTAssertThrowsError(try connector().plan(.claudeDesktop, entry: ServerEntry(pcapMCP: server, grantId: "grn_new"))) { error in
                guard case ConnectError.unreadable = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        }
    }

    // MARK: Claude Code, through `claude mcp`

    func testClaudeCodeIsAddedAtUserScopeThroughItsOwnCommand() throws {
        let (claude, log) = try fakeClaude()
        let file = try write(#"{"projects": {"/code/app": {"mcpServers": {"presence-capture": {"command": "x"}}}}, "numStartups": 3}"#, to: .claudeCode)
        let plan = try connector(claude: claude).plan(.claudeCode, entry: ServerEntry(pcapMCP: server, grantId: "grn_new"))
        XCTAssertNil(plan.replacing)
        XCTAssertEqual(plan.notes, ["In /code/app, its own presence-capture entry is used instead of this one."])
        XCTAssertNotNil(try connector(claude: claude).apply(plan), "~/.claude.json wasn't copied aside")

        let ran = try commands(log)
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(Array(ran[0].prefix(3)), ["mcp", "add-json", "presence-capture"])
        XCTAssertEqual(Array(ran[0].suffix(2)), ["--scope", "user"])
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ran[0][3].utf8)) as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, server)
        XCTAssertEqual(entry["args"] as? [String], ["--grant", "grn_new"])
        XCTAssertEqual(entry["type"] as? String, "stdio")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("numStartups"), "Claude Code's own file was rewritten")
    }

    func testClaudeCodesExistingEntryIsRemovedThenAdded() throws {
        let (claude, log) = try fakeClaude()
        _ = try write(#"{"mcpServers": {"presence-capture": {"type": "stdio", "command": "/old", "args": ["--grant", "grn_old"]}}}"#, to: .claudeCode)
        let plan = try connector(claude: claude).plan(.claudeCode, entry: ServerEntry(pcapMCP: server, grantId: "grn_new"))
        XCTAssertEqual(plan.replacing, "grn_old")
        try connector(claude: claude).apply(plan)
        XCTAssertEqual(try commands(log).map { Array($0.prefix(2)) }, [["mcp", "remove"], ["mcp", "add-json"]])
    }

    func testWithoutClaudeTheCommandToRunIsGivenQuoted() throws {
        XCTAssertThrowsError(try connector(claude: nil).plan(.claudeCode, entry: ServerEntry(pcapMCP: server, grantId: "grn_new"))) { error in
            guard case ConnectError.claudeNotFound(let command) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(command.hasPrefix("claude mcp add-json presence-capture '{"), command)
            XCTAssertTrue(command.hasSuffix(" --scope user"), command)
        }
    }

    // MARK: The whole connect, with a store

    private func store() throws -> CaptureStore {
        try CaptureStore(path: home.appendingPathComponent("store/store.sqlite").path, masterKey: Seal.newKey())
    }

    private func grant(_ client: Client) -> NewGrant { NewGrant(clientId: client.rawValue, expiresAt: Date().addingTimeInterval(86_400)) }

    private func entry(_ grantId: String) -> ServerEntry { ServerEntry(pcapMCP: server, grantId: grantId) }

    func testDecliningWritesNothingAndWithdrawsTheGrant() throws {
        let store = try store()
        let file = try write("{}", to: .cursor)
        var shown: ConnectPlan?
        let connection = try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { plan in
            shown = plan
            return false
        }
        XCTAssertNil(connection)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{}")
        let grants = try store.grants()
        XCTAssertEqual(grants.map(\.grantId), [shown?.grantId])
        XCTAssertNotNil(grants[0].revokedAt, "a declined connection left its grant readable")
    }

    func testConnectingAgainRevokesTheGrantItReplaces() throws {
        let store = try store()
        let first = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        let second = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        XCTAssertEqual(second.revoked, first.grantId)
        let active = try store.grants().filter { $0.isActive() }.map(\.grantId)
        XCTAssertEqual(active, [second.grantId])
        let entry = (try json(connector().file(for: .cursor))["mcpServers"] as? [String: Any])?["presence-capture"] as? [String: Any]
        XCTAssertEqual(entry?["args"] as? [String], ["--grant", second.grantId])
    }

    func testAFailedWriteWithdrawsTheGrant() throws {
        let store = try store()
        let (claude, _) = try fakeClaude(failing: true)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, grant: grant(.claudeCode), entry: entry) { _ in true }) { error in
            guard case ConnectError.claudeFailed(_, let output) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(output.contains("refused"))
        }
        XCTAssertTrue(try store.grants().allSatisfy { $0.revokedAt != nil }, "a connection that failed left its grant readable")
    }

    // MARK: What can go wrong (inspection F1)

    func testAConfigChangedWhileTheChangeIsShownIsShownAgainNotWrittenOver() throws {
        let store = try store()
        let file = try write(#"{"mcpServers": {}}"#, to: .cursor)
        var shown = 0
        let connection = try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { plan in
            shown += 1
            // While the first is on screen, Cursor adds a server of its own.
            if shown == 1 { try Data(#"{"mcpServers": {"theirs": {"command": "/bin/theirs"}}}"#.utf8).write(to: file) }
            else { XCTAssertTrue(plan.diff.contains("theirs"), "the change was shown again without what changed") }
            return true
        }
        XCTAssertNotNil(connection)
        XCTAssertEqual(shown, 2, "a changed config was written over without asking again")
        let servers = try XCTUnwrap(try json(file)["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["theirs", "presence-capture"])
    }

    func testAConfigThatIsntUTF8IsRefusedNotReplaced() throws {
        let file = connector().file(for: .cursor)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0x7B, 0xFF, 0xFE, 0x7D])
        try bytes.write(to: file)
        XCTAssertThrowsError(try connector().plan(.cursor, entry: entry("grn_new"))) { error in
            XCTAssertEqual(error as? ConnectError, .unreadable(path: file.path, why: "it isn't UTF-8 text"))
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testClaudeCodesOldEntryIsPutBackWhenTheNewOneCantBeAdded() throws {
        let store = try store()
        let (claude, log) = try fakeClaude(failingOn: "grn_new")
        _ = try write(#"{"mcpServers": {"presence-capture": {"type": "stdio", "command": "/old", "args": ["--grant", "grn_old"]}}}"#, to: .claudeCode)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, grant: grant(.claudeCode),
                                                                   entry: { _ in self.entry("grn_new") }) { _ in true }) { error in
            guard case ConnectError.claudeAddFailed(_, _, let restored, let backup) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(restored, "the connection that was there wasn't put back")
            XCTAssertNotNil(backup)
        }
        let ran = try commands(log)
        XCTAssertEqual(ran.map { Array($0.prefix(2)) }, [["mcp", "remove"], ["mcp", "add-json"], ["mcp", "add-json"]])
        XCTAssertTrue(ran[2][3].contains("grn_old"), "what was put back isn't what was there")
    }

    func testAGrantThatCantBeRevokedIsSaidNeverDropped() throws {
        let store = try store()
        let first = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        // The store refuses to revoke the first grant, as a write lock held past its timeout would.
        try store.exec("CREATE TRIGGER held BEFORE UPDATE ON grant_record WHEN OLD.grant_id = '\(first.grantId)' BEGIN SELECT RAISE(ABORT, 'held'); END")
        let second = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        XCTAssertNil(second.revoked)
        XCTAssertEqual(second.stillActive?.grantId, first.grantId, "a replaced grant left readable wasn't reported")

        try store.exec("DROP TRIGGER held")
        try store.exec("CREATE TRIGGER held BEFORE UPDATE ON grant_record BEGIN SELECT RAISE(ABORT, 'held'); END")
        XCTAssertThrowsError(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in false }) { error in
            guard case ConnectError.grantLeft = error else { return XCTFail("a declined connection's grant was left readable quietly: \(error)") }
        }
    }

    func testAnEntryNamesTheStoreAndKeyFileWhenTheyArentTheApps() {
        XCTAssertEqual(ServerEntry(pcapMCP: server, grantId: "grn_a").args, ["--grant", "grn_a"])
        XCTAssertEqual(ServerEntry(pcapMCP: server, grantId: "grn_a", store: "/s/store.sqlite", keyFile: "/s/key").args,
                       ["--grant", "grn_a", "--store", "/s/store.sqlite", "--master-key-file", "/s/key"])
    }

    // MARK: pcap, the command line

    /// The built `pcap`, beside this test bundle.
    private func pcap(_ arguments: [String], in directory: URL? = nil) throws -> (status: Int32, output: String) {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let process = Process()
        process.executableURL = products.appendingPathComponent("pcap")
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, said)
    }

    func testPcapRefusesWhatACommandDoesntTakeBeforeTouchingAnything() throws {
        let store = home.appendingPathComponent("absent.sqlite").path
        for (arguments, said) in [(["forget", "15m", "--dry-run"], "forget doesn't take --dry-run"),
                                  (["grant", "add", "agent", "--type", "screen_text"], "grant add doesn't take --type"),
                                  (["grant", "list", "extra"], "too many words"),
                                  (["check", "--yes"], "check doesn't take --yes")] {
            let ran = try pcap(arguments + ["--store", store])
            XCTAssertEqual(ran.status, 2, "\(arguments): \(ran.output)")
            XCTAssertTrue(ran.output.contains(said), "\(arguments): \(ran.output)")
        }
    }

    func testPcapConnectNamesPcapMCPByAnAbsolutePath() throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let server = bin.appendingPathComponent("pcap-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let ran = try pcap(["connect", "cursor", "--dry-run", "--pcap-mcp", "./pcap-mcp"], in: bin)
        XCTAssertEqual(ran.status, 0, ran.output)
        XCTAssertTrue(ran.output.contains("\"command\": \"\(server.standardizedFileURL.path)\""), ran.output)
    }

    // MARK: Showing the change

    func testTheDiffShowsChangesWithContextAndSkipsTheRest() {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "line 3\n", with: "line three\n").replacingOccurrences(of: "line 18\n", with: "")
        XCTAssertEqual(LineDiff.render(before, after), """
              line 1
              line 2
            - line 3
            + line three
              line 4
              line 5
              …
              line 16
              line 17
            - line 18
              line 19
              line 20
            """)
        XCTAssertEqual(LineDiff.render("", "{}\n"), "+ {}")
    }
}
