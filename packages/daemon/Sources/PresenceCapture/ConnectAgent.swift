import AppKit
import CaptureConnect
import CaptureStore

/// Connect an Agent… (R2): what `pcap connect` does, through the same CaptureConnect code. The
/// agent gets a grant of its own and `pcap-mcp` in its MCP config. The change is shown, with its
/// diff, and asked about first; the config is copied aside before it's written.
enum ConnectAgent {
    /// What a connection from the menu may read: standard captures of every type, for 30 days.
    static let days = 30

    /// `storePath` is the app's store; named in the entry only when it isn't where pcap-mcp looks
    /// by itself (PRESENCE_CAPTURE_HOME moved it).
    static func run(_ client: Client, store: CaptureStore, storePath: String, log: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        // Beside the app's own executable: Contents/MacOS in the bundle, the build folder in development.
        guard let server = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("pcap-mcp").path,
              FileManager.default.isExecutableFile(atPath: server) else {
            return tell("Nothing was connected", "pcap-mcp, the server agents start, isn't in the app. Reinstall Presence Capture.")
        }
        let grant = NewGrant(clientId: client.rawValue, expiresAt: Date().addingTimeInterval(Double(days) * 86_400))
        do {
            let other = storePath == CaptureStore.defaultHome + "/store.sqlite" ? nil : storePath
            guard let connection = try Connector().connect(client, store: store, grant: grant,
                                                           entry: { ServerEntry(pcapMCP: server, grantId: $0, store: other) },
                                                           confirm: { confirm($0, grant: grant) }) else {
                log("connect.declined client=\(client.rawValue)")
                return
            }
            log("connect.done client=\(client.rawValue) replaced=\(connection.revoked != nil)")
            var said = ["\(client.name) reads Presence Capture through a grant of its own until \(date(connection.expiresAt)). Withdraw it any time in Agents Read….",
                        client.afterward]
            if let backup = connection.backup { said.append("Its config as it was is copied to \(backup.path).") }
            if connection.revoked != nil { said.append("The grant of the connection it replaced is withdrawn.") }
            if connection.stillActive != nil {
                log("connect.replaced_grant_left client=\(client.rawValue)")
                said.append("The grant of the connection it replaced couldn't be withdrawn, and can still read: withdraw it in Agents Read….")
            }
            tell("\(client.name) is connected", said.joined(separator: "\n\n"))
        } catch ConnectError.claudeNotFound(let command) {
            log("connect.failed client=\(client.rawValue) why=no_claude")
            let alert = NSAlert()
            alert.messageText = "Claude Code's command wasn't found"
            alert.informativeText = "Nothing was connected. Install Claude Code, then try again, or run this in Terminal:\n\n\(command)"
            alert.addButton(withTitle: "Copy the Command")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        } catch {
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
