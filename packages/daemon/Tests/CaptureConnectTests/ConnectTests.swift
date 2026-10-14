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

    private func connector(claude: URL? = nil, environment: [String: String] = [:]) -> Connector {
        Connector(environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(environment) { $1 }, home: home, claude: .some(claude),
                  now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private var storePath: String { home.appendingPathComponent("store/store.sqlite").path }

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
        let plan = try connector().plan(.claudeDesktop, entry: ServerEntry(pcapMCP: server, grantId: "grn_new", store: storePath))
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
        XCTAssertEqual(entry["args"] as? [String], ["--grant", "grn_new", "--store", storePath])
        XCTAssertNil(entry["type"], "Claude Desktop's documented entry has no type")
        let preferences = try XCTUnwrap(after["preferences"] as? [String: Any])
        XCTAssertEqual(preferences["ratio"] as? Double, 1.5)
        XCTAssertEqual(preferences["on"] as? Bool, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int, 0o600,
                       "the config's permissions were loosened")
    }

    func testCursorWithNoConfigYetGetsOneAndNoBackup() throws {
        let plan = try connector().plan(.cursor, entry: ServerEntry(pcapMCP: server, grantId: "grn_new", store: storePath))
        XCTAssertNil(try connector().apply(plan))
        let entry = try XCTUnwrap((try json(connector().file(for: .cursor))["mcpServers"] as? [String: Any])?["presence-capture"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "stdio")
        XCTAssertEqual(entry["command"] as? String, server)
    }

    func testAnEntryAlreadyThereIsReplacedAndItsGrantNamed() throws {
        _ = try write(#"{"mcpServers": {"presence-capture": {"command": "/old/pcap-mcp", "args": ["--grant", "grn_old"]}}}"#, to: .cursor)
        let plan = try connector().plan(.cursor, entry: ServerEntry(pcapMCP: server, grantId: "grn_new", store: storePath))
        XCTAssertEqual(plan.replacing, "grn_old")
        XCTAssertTrue(plan.diff.contains("-") && plan.diff.contains("grn_old") && plan.diff.contains("+") && plan.diff.contains("grn_new"), plan.diff)
    }

    func testAConfigThatIsntAJSONObjectIsLeftAlone() throws {
        for text in ["{ not json", "[1, 2]", #"{"mcpServers": ["a list"]}"#] {
            let file = try write(text, to: .claudeDesktop)
            XCTAssertThrowsError(try connector().plan(.claudeDesktop, entry: ServerEntry(pcapMCP: server, grantId: "grn_new", store: storePath))) { error in
                guard case ConnectError.unreadable = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        }
    }

    // MARK: Claude Code, through `claude mcp`

    func testClaudeCodeIsAddedAtUserScopeThroughItsOwnCommand() throws {
        let (claude, log) = try fakeClaude()
        let file = try write(#"{"projects": {"/code/app": {"mcpServers": {"presence-capture": {"command": "x"}}}}, "numStartups": 3}"#, to: .claudeCode)
        let plan = try connector(claude: claude).plan(.claudeCode, entry: ServerEntry(pcapMCP: server, grantId: "grn_new", store: storePath))
        XCTAssertNil(plan.replacing)
        XCTAssertEqual(plan.notes, ["In /code/app, its own presence-capture entry is used instead of this one."])
        XCTAssertNotNil(try connector(claude: claude).apply(plan), "~/.claude.json wasn't copied aside")

        let ran = try commands(log)
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(Array(ran[0].prefix(3)), ["mcp", "add-json", "presence-capture"])
        XCTAssertEqual(Array(ran[0].suffix(2)), ["--scope", "user"])
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ran[0][3].utf8)) as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, server)
        XCTAssertEqual(entry["args"] as? [String], ["--grant", "grn_new", "--store", storePath])
        XCTAssertEqual(entry["type"] as? String, "stdio")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("numStartups"), "Claude Code's own file was rewritten")
    }

    func testClaudeCodesExistingEntryIsRemovedThenAdded() throws {
        let (claude, log) = try fakeClaude()
        _ = try write(#"{"mcpServers": {"presence-capture": {"type": "stdio", "command": "/old", "args": ["--grant", "grn_old"]}}}"#, to: .claudeCode)
        let plan = try connector(claude: claude).plan(.claudeCode, entry: ServerEntry(pcapMCP: server, grantId: "grn_new", store: storePath))
        XCTAssertEqual(plan.replacing, "grn_old")
        try connector(claude: claude).apply(plan)
        XCTAssertEqual(try commands(log).map { Array($0.prefix(2)) }, [["mcp", "remove"], ["mcp", "add-json"]])
    }

    func testWithoutClaudeNothingIsIssued() throws {
        let store = try store()
        XCTAssertThrowsError(try connector(claude: nil).connect(.claudeCode, store: store, grant: grant(.claudeCode), entry: entry) { _ in true }) { error in
            XCTAssertEqual(error as? ConnectError, .claudeNotFound)
        }
        XCTAssertTrue(try store.grants().isEmpty, "a grant was issued for a connection that couldn't be made")
    }

    func testAClaudeConfigFolderOfItsOwnIsRefusedBeforeAnything() throws {
        let store = try store()
        let (claude, log) = try fakeClaude()
        XCTAssertThrowsError(try connector(claude: claude, environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("elsewhere").path])
            .connect(.claudeCode, store: store, grant: grant(.claudeCode), entry: entry) { _ in true }) { error in
            guard case ConnectError.unsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(try store.grants().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "claude was run")
    }

    // MARK: The whole connect, with a store

    private func store() throws -> CaptureStore {
        try CaptureStore(path: storePath, masterKey: Seal.newKey())
    }

    private func grant(_ client: Client) -> NewGrant { NewGrant(clientId: client.rawValue, expiresAt: Date().addingTimeInterval(86_400)) }

    private func entry(_ grantId: String) -> ServerEntry { ServerEntry(pcapMCP: server, grantId: grantId, store: storePath) }

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
        XCTAssertEqual(entry?["args"] as? [String], ["--grant", second.grantId, "--store", storePath])
    }

    func testAFailedWriteWithdrawsTheGrant() throws {
        let store = try store()
        let (claude, _) = try fakeClaude(failing: true)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, grant: grant(.claudeCode), entry: entry) { _ in true }) { error in
            guard case ConnectError.claudeAddFailed(_, let output, let restored, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(output.contains("refused"))
            XCTAssertTrue(restored, "nothing was changed, and it wasn't said")
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
        let claude = try claudeEditing(removeFails: false, addFailsOn: "grn_new")
        _ = try write(#"{"mcpServers": {"presence-capture": {"type": "stdio", "command": "/old", "args": ["--grant", "grn_old"]}}}"#, to: .claudeCode)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, grant: grant(.claudeCode),
                                                                   entry: { _ in self.entry("grn_new") }) { _ in true }) { error in
            guard case ConnectError.claudeAddFailed(_, _, let restored, let backup) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(restored, "the connection that was there wasn't put back")
            XCTAssertNotNil(backup)
        }
        let servers = try XCTUnwrap(try json(connector().file(for: .claudeCode))["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["presence-capture"] as? [String: Any])?["args"] as? [String], ["--grant", "grn_old"], "what was put back isn't what was there")
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

    func testReconnectingToAnotherStoreNamesTheOldGrantAndWhereItIs() throws {
        let store = try store()
        let elsewhere = home.appendingPathComponent("other/store.sqlite").path
        _ = try write(#"{"mcpServers": {"presence-capture": {"command": "/x", "args": ["--grant", "grn_old", "--store", "\#(elsewhere)", "--master-key-file", "/k"]}}}"#, to: .cursor)
        let connection = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        XCTAssertNil(connection.revoked)
        XCTAssertEqual(connection.stillActive?.grantId, "grn_old")
        XCTAssertTrue(connection.stillActive?.revoke.contains("--store \(elsewhere) --master-key-file /k") ?? false, connection.stillActive?.revoke ?? "")

        // In this store, but not a grant it has: said, not taken for revoked.
        _ = try write(#"{"mcpServers": {"presence-capture": {"command": "/x", "args": ["--grant", "grn_unknown", "--store", "\#(storePath)"]}}}"#, to: .cursor)
        let again = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        XCTAssertEqual(again.stillActive?.why, "it isn't in this store")
    }

    func testAClaudeThatCantBeStartedAfterRemovingIsStillReportedWithTheBackup() throws {
        let store = try store()
        let (claude, _) = try fakeClaude()
        // On `mcp remove` it removes the entry, then itself, as an update replacing it mid-connection could.
        let file = connector().file(for: .claudeCode).path
        try Data("#!/bin/sh\ncase \"$2\" in remove) printf '{\"mcpServers\": {}}' > '\(file)'; rm -f \"$0\";; esac\nexit 0\n".utf8).write(to: claude)
        _ = try write(#"{"mcpServers": {"presence-capture": {"type": "stdio", "command": "/old", "args": ["--grant", "grn_old"]}}}"#, to: .claudeCode)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, grant: grant(.claudeCode), entry: entry) { _ in true }) { error in
            guard case ConnectError.claudeAddFailed(_, _, let restored, let backup) = error else { return XCTFail("not reported as a failed add: \(error)") }
            XCTAssertFalse(restored)
            XCTAssertNotNil(backup)
        }
    }

    func testAReplacedEntrysStoreIsFoundAsItsServerWouldFindIt() throws {
        let store = try store()
        _ = try write(#"{"mcpServers": {"presence-capture": {"command": "/x", "args": ["--grant", "grn_old"], "env": {"PRESENCE_CAPTURE_HOME": "/other"}}}}"#, to: .cursor)
        let moved = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        XCTAssertEqual(moved.stillActive?.why, "it's in another store, /other/store.sqlite")
        XCTAssertTrue(moved.stillActive?.revoke.hasSuffix("grant revoke grn_old --store /other/store.sqlite") ?? false, moved.stillActive?.revoke ?? "")

        _ = try write(#"{"mcpServers": {"presence-capture": {"command": "/x", "args": ["--grant", "grn_old"], "env": {"PRESENCE_CAPTURE_HOME": "relative"}}}}"#, to: .cursor)
        let unknown = try XCTUnwrap(try connector().connect(.cursor, store: store, grant: grant(.cursor), entry: entry) { _ in true })
        XCTAssertTrue(unknown.stillActive?.why.contains("can't be known") ?? false)
    }

    /// A stand-in `claude` running `script`, with a marker in its command line to look for afterwards.
    private func claudeRunning(_ script: String) throws -> (claude: URL, marker: String) {
        let marker = "pcap-test-\(UUID().uuidString.prefix(8))"
        let claude = home.appendingPathComponent("claude")
        try Data("#!/bin/sh\n# \(marker)\n\(script)\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return (claude, marker)
    }

    private func running(_ marker: String) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let out = Pipe()
        ps.standardOutput = out
        try? ps.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return text.contains(marker)
    }

    func testAClaudeThatHangsIsStoppedAtTheDeadlineWithWhatItStarted() throws {
        let (claude, marker) = try claudeRunning("sleep 30 # child\nsleep 30")
        var connector = connector(claude: claude)
        connector.claudeWait = 1
        let plan = try connector.plan(.claudeCode, entry: entry("grn_new"))
        let started = Date()
        XCTAssertThrowsError(try connector.apply(plan)) { error in
            guard case ConnectError.claudeAddFailed(_, let output, _, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(output.contains("didn't finish"), output)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(running(marker), "claude, or what it started, was left running")
    }

    /// A stand-in `claude` that edits the config as the real one does, then fails as told.
    private func claudeEditing(removeFails: Bool, addFailsOn: String?) throws -> URL {
        let file = connector().file(for: .claudeCode).path
        return try claudeRunning("""
            case "$2" in
            remove) printf '{"mcpServers": {}}' > '\(file)'; \(removeFails ? "exit 1" : "exit 0");;
            add-json) printf '{"mcpServers": {"presence-capture": %s}}' "$4" > '\(file)'; \(addFailsOn.map { "case \"$4\" in *\($0)*) exit 1;; esac" } ?? ""); exit 0;;
            esac
            """).claude
    }

    func testARemoveThatChangesTheConfigThenFailsIsPutBack() throws {
        let store = try store()
        let claude = try claudeEditing(removeFails: true, addFailsOn: nil)
        _ = try write(#"{"mcpServers": {"presence-capture": {"type": "stdio", "command": "/old", "args": ["--grant", "grn_old"]}}}"#, to: .claudeCode)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, grant: grant(.claudeCode), entry: entry) { _ in true }) { error in
            guard case ConnectError.claudeAddFailed(_, _, let restored, let backup) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(restored, "the entry a failed remove took wasn't put back")
            XCTAssertNotNil(backup)
        }
        let servers = try XCTUnwrap(try json(connector().file(for: .claudeCode))["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["presence-capture"] as? [String: Any])?["args"] as? [String], ["--grant", "grn_old"])
    }

    func testAnAddThatWritesThenFailsLeavesNoEntryWhereThereWasNone() throws {
        let store = try store()
        let claude = try claudeEditing(removeFails: false, addFailsOn: "--store")
        _ = try write(#"{"mcpServers": {}}"#, to: .claudeCode)
        XCTAssertThrowsError(try connector(claude: claude).connect(.claudeCode, store: store, grant: grant(.claudeCode), entry: entry) { _ in true }) { error in
            guard case ConnectError.claudeAddFailed(_, _, let restored, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(restored)
        }
        let servers = try json(connector().file(for: .claudeCode))["mcpServers"] as? [String: Any]
        XCTAssertNil(servers?["presence-capture"], "an entry naming a withdrawn grant was left")
    }

    func testAWorkerThatIgnoresBeingAskedIsStoppedWhenClaudeTimesOut() throws {
        let marker = "pcap-test-\(UUID().uuidString.prefix(8))"
        // claude exits when asked; what it started ignores being asked, and would go on.
        let (claude, _) = try claudeRunning("sh -c 'trap \"\" TERM; sleep 30 # \(marker)' &\ntrap 'exit 0' TERM\nsleep 30 & wait")
        var connector = connector(claude: claude)
        connector.claudeWait = 1
        let plan = try connector.plan(.claudeCode, entry: entry("grn_new"))
        XCTAssertThrowsError(try connector.apply(plan))
        XCTAssertFalse(running(marker), "a worker that ignores SIGTERM outlived the connection")
    }

    func testWhatClaudeLeavesHoldingItsOutputIsStoppedNotWaitedFor() throws {
        let marker = "pcap-test-\(UUID().uuidString.prefix(8))"
        let (claude, _) = try claudeRunning("sh -c 'sleep 30 # \(marker)' &\nexit 0")
        let plan = try connector(claude: claude).plan(.claudeCode, entry: entry("grn_new"))
        let started = Date()
        XCTAssertNoThrow(try connector(claude: claude).apply(plan))
        XCTAssertLessThan(Date().timeIntervalSince(started), 9, "a descendant holding the output was waited for")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(running(marker), "what claude started was left running")
    }

    func testAnEntryNamesTheStoreAndKeyFileWhenTheyArentTheApps() {
        XCTAssertEqual(ServerEntry(pcapMCP: server, grantId: "grn_a", store: "/s/store.sqlite").args, ["--grant", "grn_a", "--store", "/s/store.sqlite"])
        XCTAssertEqual(ServerEntry(pcapMCP: server, grantId: "grn_a", store: "/s/store.sqlite", keyFile: "/s/key").args,
                       ["--grant", "grn_a", "--store", "/s/store.sqlite", "--master-key-file", "/s/key"])
        let bundled = Connector(environment: [:], home: home, claude: .some(nil), pcap: "/Applications/Presence Capture.app/Contents/MacOS/pcap")
        XCTAssertEqual(bundled.revokeCommand(["--grant", "grn_a", "--master-key-file", "/s/key"], store: "/s/my store.sqlite"),
                       "'/Applications/Presence Capture.app/Contents/MacOS/pcap' grant revoke grn_a --store '/s/my store.sqlite' --master-key-file /s/key")
        XCTAssertEqual(Connector.shellQuoted("it's $(here)"), #"'it'\''s $(here)'"#)
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
