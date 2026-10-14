import CaptureStore
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
    private func fakeClaude(failing: Bool = false) throws -> (claude: URL, log: URL) {
        let bin = home.appendingPathComponent("fake bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("claude.log")
        let claude = bin.appendingPathComponent("claude")
        try Data("""
            #!/bin/sh
            for a in "$@"; do printf '%s\\n' "$a" >> '\(log.path)'; done
            printf -- '--\\n' >> '\(log.path)'
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

    func testDecliningWritesNothingAndWithdrawsTheGrant() throws {
        let store = try store()
        let file = try write("{}", to: .cursor)
        var shown: ConnectPlan?
        let connection = try connector().connect(.cursor, store: store, pcapMCP: server, grant: grant(.cursor)) { plan in
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
        let first = try XCTUnwrap(try connector().connect(.cursor, store: store, pcapMCP: server, grant: grant(.cursor)) { _ in true })
        let second = try XCTUnwrap(try connector().connect(.cursor, store: store, pcapMCP: server, grant: grant(.cursor)) { _ in true })
        XCTAssertEqual(second.revoked, first.grantId)
        let active = try store.grants().filter { $0.isActive() }.map(\.grantId)
        XCTAssertEqual(active, [second.grantId])
        let entry = (try json(connector().file(for: .cursor))["mcpServers"] as? [String: Any])?["presence-capture"] as? [String: Any]
        XCTAssertEqual(entry?["args"] as? [String], ["--grant", second.grantId])
    }

    func testAFailedWriteWithdrawsTheGrant() throws {
        let store = try store()
        let (claude, _) = try fakeClaude(failing: true)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, pcapMCP: server, grant: grant(.claudeCode)) { _ in true }) { error in
            guard case ConnectError.claudeFailed(_, let output) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(output.contains("refused"))
        }
        XCTAssertTrue(try store.grants().allSatisfy { $0.revokedAt != nil }, "a connection that failed left its grant readable")
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
