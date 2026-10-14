import AppKit
import CaptureConnect
import CaptureStore

/// Connect an Agent… (R2): what `pcap connect` does, through the same CaptureConnect code. The
/// agent gets a grant of its own and `pcap-mcp` in its MCP config. The change is shown, with its
/// diff, and asked about first; the config is copied aside before it's written.
enum ConnectAgent {
    /// What a connection from the menu may read: standard captures of every type, for 30 days.
    static let days = 30

    /// One connection at a time from the menu (read and written on the main thread).
    private static var connecting = false

    /// `storePath` is the app's store, named in the entry by its absolute path.
    ///
    /// The work runs off the main thread: the store, another connection's turn and `claude` can each
    /// take a while, and the main thread is where locking, sleep and Pause are heard. Only the
    /// confirmation and the result are shown on it.
    static func run(_ client: Client, store: CaptureStore, storePath: String, log: @escaping @Sendable (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        guard !connecting else { return tell("A connection is under way", "Finish it before starting another.") }
        // Beside the app's own executable: Contents/MacOS in the bundle, the build folder in development.
        guard let server = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("pcap-mcp").path,
              FileManager.default.isExecutableFile(atPath: server) else {
            return tell("Nothing was connected", "pcap-mcp, the server agents start, isn't in the app. Reinstall Presence Capture.")
        }
        let grant = NewGrant(clientId: client.rawValue, expiresAt: Date().addingTimeInterval(Double(days) * 86_400))
        let path = URL(fileURLWithPath: storePath).standardizedFileURL.path
        // pcap by its full path, for any command shown: a DMG install doesn't put it on PATH.
        let pcap = URL(fileURLWithPath: server).deletingLastPathComponent().appendingPathComponent("pcap").path
        connecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try Connector(pcap: pcap).connect(client, store: store, grant: grant,
                                                  entry: { ServerEntry(pcapMCP: server, grantId: $0, store: path) },
                                                  confirm: { plan in DispatchQueue.main.sync { confirm(plan, grant: grant) } })
            }
            // Whether a grant left active is one Agents Read… can withdraw: one in this store.
            let leftHere = (try? result.get()?.stillActive).flatMap { left in
                left.flatMap { left in try? store.grants().contains { $0.grantId == left.grantId && $0.isActive() } }
            } ?? false
            DispatchQueue.main.async {
                connecting = false
                show(result, client: client, leftHere: leftHere, log: log)
            }
        }
    }

    private static func show(_ result: Result<Connection?, Error>, client: Client, leftHere: Bool, log: (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        switch result {
        case .success(nil):
            log("connect.declined client=\(client.rawValue)")
        case .success(let connection?):
            log("connect.done client=\(client.rawValue) replaced=\(connection.revoked != nil)")
            var said = ["\(client.name) reads Presence Capture through a grant of its own until \(date(connection.expiresAt)). Withdraw it any time in Agents Read….",
                        client.afterward]
            if let backup = connection.backup { said.append("Its config as it was is copied to \(backup.path).") }
            if connection.revoked != nil { said.append("The grant of the connection it replaced is withdrawn.") }
            if let left = connection.stillActive {
                log("connect.replaced_grant_left client=\(client.rawValue)")
                said.append("The grant of the connection it replaced couldn't be withdrawn (\(left.why)), and can still read. "
                    + (leftHere ? "Withdraw it in Agents Read…, or with:\n\(left.revoke)" : "It isn't in this store, so Agents Read… can't withdraw it. In Terminal:\n\(left.revoke)"))
            }
            tell("\(client.name) is connected", said.joined(separator: "\n\n"))
        case .failure(ConnectError.claudeNotFound):
            log("connect.failed client=\(client.rawValue) why=no_claude")
            tell("Claude Code's command wasn't found", "Nothing was connected. Install Claude Code, then choose Connect an Agent → Claude Code again.")
        case .failure(let error):
            log("connect.failed client=\(client.rawValue)")
            tell("Nothing was connected", "\(error)")
        }
    }

    /// The change, as `pcap connect` shows it: what the agent may read, the file, and the diff.
    private static func confirm(_ plan: ConnectPlan, grant: NewGrant) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Connect \(plan.client.name) to Presence Capture?"
        var said = ["\(plan.client.name) gets a grant of its own: what you capture at the standard level, of every kind, until \(date(grant.expiresAt)).",
                    "This changes \(plan.file.path)\(plan.client == .claudeCode ? ", through Claude Code's own `claude mcp` command" : "")."]
        if FileManager.default.fileExists(atPath: plan.file.path) { said.append("It's copied aside first, beside itself.") }
        if plan.replacing != nil { said.append("It replaces the connection already there, and withdraws that one's grant.") }
        said += plan.notes
        alert.informativeText = said.joined(separator: "\n\n")
        alert.accessoryView = diffView(plan.diff)
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func diffView(_ diff: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 220)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let styled = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let color: NSColor = line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : .secondaryLabelColor
            styled.append(NSAttributedString(string: line + "\n", attributes: [.foregroundColor: color, .font: text.font!]))
        }
        text.textStorage?.setAttributedString(styled)
        return scroll
    }

    private static func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
