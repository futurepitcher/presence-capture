import CaptureConnect
import CaptureStore
import SwiftUI

/// Agents Read…: every agent's grant, and what each was given, day by day, from the egress log,
/// which records every read. Counts and kinds only: what was read is never shown here.
struct AgentsReadView: View {
    struct Snapshot {
        var grants: [GrantInfo] = []
        var egress: [EgressDay] = []
    }

    /// Reads the grants and the last week of the log; throws when the store can't be read.
    let load: () throws -> Snapshot
    /// Withdraws a grant.
    let revoke: (String) throws -> Void

    @State private var snapshot = Snapshot()
    @State private var problem: String?
    /// A withdrawal that failed: kept through a reload, since the grant can still read.
    @State private var failure: String?
    @State private var withdrawing: GrantInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Agents that can read Presence Capture").font(.headline)
                Spacer()
                Button("Refresh", action: reload)
            }
            if let problem { Text(problem).foregroundStyle(.red) }
            if let failure { Text(failure).foregroundStyle(.red) }
            grantsSection
            Divider()
            readsSection
            Text("From the egress log, which records every read an agent makes. What was read is never shown here.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
        .onAppear(perform: reload)
        .confirmationDialog("Withdraw this grant?", isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }),
                            presenting: withdrawing) { grant in
            Button("Withdraw \(Self.name(grant.clientId))'s Grant", role: .destructive) {
                do {
                    try revoke(grant.grantId)
                    failure = nil
                } catch {
                    failure = "\(Self.name(grant.clientId))'s grant couldn't be withdrawn, and can still read. Try again in a moment."
                }
                reload()
            }
        } message: { grant in
            Text("\(Self.name(grant.clientId)) can't read anything from now on. Connect it again to give it a new grant.")
        }
    }

    private var grantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grants").font(.subheadline).bold()
            if snapshot.grants.isEmpty {
                Text("No agent has a grant. Choose Connect an Agent in the menu to give one.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.grants, id: \.grantId) { grant in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.name(grant.clientId)).bold()
                        Text(Self.scope(grant)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.state(grant)).foregroundStyle(grant.isActive() ? .primary : .secondary)
                    if grant.isActive() {
                        Button("Withdraw…") { withdrawing = grant }
                    }
                }
            }
        }
    }

    private var readsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What they read, the last 7 days").font(.subheadline).bold()
            if snapshot.egress.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ScrollView { ReadsList(egress: snapshot.egress).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func reload() {
        do {
            snapshot = try load()
            problem = nil
        } catch {
            problem = "The store couldn't be read."
        }
    }

    /// What the log has, a day at a time: each agent's reads by tool.
    struct ReadsList: View {
        let egress: [EgressDay]

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AgentsReadView.days(egress), id: \.day) { day in
                    Text(day.day).font(.caption).foregroundStyle(.secondary)
                    ForEach(day.lines, id: \.id) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(AgentsReadView.name(line.clientId)).frame(width: 120, alignment: .leading)
                            Text(line.tool).font(.system(.body, design: .monospaced)).frame(width: 90, alignment: .leading)
                            Text(AgentsReadView.summary(line.line)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Words

    /// A connected client by its name; any other agent by the name its grant was given.
    static func name(_ clientId: String) -> String { Client(rawValue: clientId)?.name ?? clientId }

    static func scope(_ grant: GrantInfo) -> String {
        let types = grant.captureTypes == ["*"] ? "every kind" : grant.captureTypes.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
        return "\(grant.privacyLevels.joined(separator: ", ")) · \(types) · up to \(grant.maxRowsPerQuery) a read"
    }

    static func state(_ grant: GrantInfo, now: Date = Date()) -> String {
        let date = { (d: Date) in d.formatted(date: .abbreviated, time: .omitted) }
        if let revoked = grant.revokedAt { return "Withdrawn \(date(revoked))" }
        return grant.expiresAt > now ? "Until \(date(grant.expiresAt))" : "Expired \(date(grant.expiresAt))"
    }

    static func summary(_ line: EgressDay) -> String {
        let reads = "\(line.reads.formatted()) \(line.reads == 1 ? "read" : "reads"), \(line.rows.formatted()) \(line.rows == 1 ? "item" : "items")"
        if line.tool == "index" { return "\(reads), into its search index on this Mac" }
        let kinds = line.types.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key.replacingOccurrences(of: "_", with: " "))" }
        return kinds.isEmpty ? reads : "\(reads): \(kinds.joined(separator: ", "))"
    }

    struct Day {
        let day: String
        let lines: [Line]
    }

    struct Line {
        let id: String
        let clientId: String
        let tool: String
        let line: EgressDay
    }

    /// The log's lines grouped by day, newest first, as `egress(since:)` orders them.
    static func days(_ egress: [EgressDay]) -> [Day] {
        var out: [Day] = []
        for line in egress {
            let entry = Line(id: "\(line.day) \(line.clientId) \(line.tool)", clientId: line.clientId, tool: line.tool, line: line)
            if out.last?.day == line.day { out[out.count - 1] = Day(day: line.day, lines: out[out.count - 1].lines + [entry]) }
            else { out.append(Day(day: line.day, lines: [entry])) }
        }
        return out
    }
}
