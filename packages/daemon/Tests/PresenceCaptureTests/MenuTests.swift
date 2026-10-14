import AppKit
@testable import CaptureConnect
@testable import CaptureStore
import SwiftUI
import XCTest
@testable import PresenceCapture

/// The menu's windows and checks, without the menu: what they decide and say, and that they draw.
final class MenuTests: XCTestCase {
    // MARK: Check for Updates

    private func answer(tag: String, page: String = "https://github.com/futurepitcher/presence-capture/releases/tag/v0.2.0") -> Data {
        Data(#"{"tag_name": "\#(tag)", "html_url": "\#(page)", "draft": false}"#.utf8)
    }

    func testANewerReleaseIsOfferedAndNothingElseIs() {
        XCTAssertTrue(Updates.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(Updates.isNewer("0.10.0", than: "0.9.1"), "versions compared as text")
        XCTAssertTrue(Updates.isNewer("0.1.1", than: "0.1"))
        XCTAssertFalse(Updates.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(Updates.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(Updates.isNewer("0.0.9", than: "0.1.0"))
        XCTAssertFalse(Updates.isNewer("1.0.0-rc1", than: "0.1.0"), "a version that isn't numbers was offered")

        let release = Updates.Release(version: "0.2.0", page: URL(string: "https://github.com/futurepitcher/presence-capture/releases/tag/v0.2.0")!)
        XCTAssertEqual(Updates.outcome(status: 200, data: answer(tag: "v0.2.0"), current: "0.1.0"), .newer(release))
        XCTAssertEqual(Updates.outcome(status: 200, data: answer(tag: "v0.1.0"), current: "0.1.0"), .upToDate(latest: "0.1.0"))
        XCTAssertEqual(Updates.outcome(status: 404, data: nil, current: "0.1.0"), .noRelease)
        XCTAssertEqual(Updates.outcome(status: 403, data: answer(tag: "v9.0.0"), current: "0.1.0"), .unknown, "a rate limit read as an answer")
        XCTAssertEqual(Updates.outcome(status: nil, data: nil, current: "0.1.0"), .unknown)
    }

    func testOnlyThisRepositorysReleasePageIsOpened() {
        for page in ["http://github.com/futurepitcher/presence-capture/releases/tag/v1", "https://evil.example/futurepitcher/presence-capture/releases/x",
                     "https://github.com/someone/else/releases/tag/v1"] {
            XCTAssertNil(Updates.release(from: answer(tag: "v1.0.0", page: page)), page)
        }
    }

    // MARK: Connect an Agent

    func testAGrantLeftActiveIsAlwaysSaidWithItsCommand() {
        let left = Connection(grantId: "grn_new", expiresAt: now, backup: nil, revoked: nil,
                              stillActive: ("grn_old", "it's in another store, /other/store.sqlite", "pcap grant revoke grn_old --store /other/store.sqlite"))
        let said = ConnectAgent.warning(.success(left), client: .claudeCode)
        XCTAssertTrue(said?.contains("grn_old") ?? false)
        XCTAssertTrue(said?.contains("pcap grant revoke grn_old --store /other/store.sqlite") ?? false)
        let failed = ConnectAgent.warning(.failure(ConnectError.grantLeft(grantId: "grn_x", after: "declined", why: "busy", revoke: "pcap grant revoke grn_x")),
                                          client: .cursor)
        XCTAssertTrue(failed?.contains("pcap grant revoke grn_x") ?? false)
        XCTAssertNil(ConnectAgent.warning(.success(nil), client: .cursor))
        XCTAssertNil(ConnectAgent.warning(.failure(ConnectError.claudeNotFound), client: .claudeCode))
    }

    func testWarningsAreKeptUntilSeenAndNoConfirmationIsShownWhileQuitting() {
        let defaults = UserDefaults(suiteName: "unseen-\(UUID().uuidString)")!
        Unseen.keep("grant A", in: defaults)
        Unseen.keep("grant B", in: defaults)
        Unseen.seen("grant A", in: defaults)
        XCTAssertEqual(Unseen.all(in: defaults), ["grant B"], "a warning was lost, or kept after it was seen")

        var shown = false
        ConnectAgent.quitting = true
        defer { ConnectAgent.quitting = false }
        XCTAssertFalse(ConnectAgent.ask { shown = true; return true })
        XCTAssertFalse(shown, "a confirmation was shown after Quit")
    }

    // MARK: Keep Captures For

    func testAShorterPeriodWithNothingOlderToEraseStillStands() {
        struct Failed: Error {}
        XCTAssertTrue(AppDelegate.retentionChanged(.success(nil)), "a change with nothing to revoke was taken for a failure")
        XCTAssertTrue(AppDelegate.retentionChanged(.success(Revocation(revocationId: "rev", revokedCaptureIds: ["a"], erasedOnDisk: true))))
        XCTAssertFalse(AppDelegate.retentionChanged(.failure(Failed())))
    }

    // MARK: Agents Read

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func grant(_ client: String, expires: TimeInterval, revoked: Bool = false, types: [String] = ["*"]) -> GrantInfo {
        GrantInfo(grantId: "grn_\(client)", clientId: client, issuedAt: now.addingTimeInterval(-86_400), expiresAt: now.addingTimeInterval(expires),
                  revokedAt: revoked ? now.addingTimeInterval(-60) : nil, privacyLevels: ["standard"], captureTypes: types, sources: ["*"],
                  maxRowsPerQuery: 100)
    }

    private func line(_ day: String, _ client: String, _ tool: String, rows: Int, types: [String: Int]) -> EgressDay {
        EgressDay(day: day, clientId: client, tool: tool, reads: 2, rows: rows, bytes: 10, types: types, last: now)
    }

    func testAgentsReadSaysWhatEachGrantAllowsAndWhatWasReadInCountsOnly() {
        XCTAssertTrue(AgentsReadView.state(grant("cursor", expires: 3600), now: now).hasPrefix("Until "))
        XCTAssertTrue(AgentsReadView.state(grant("cursor", expires: -3600), now: now).hasPrefix("Expired "))
        XCTAssertTrue(AgentsReadView.state(grant("cursor", expires: 3600, revoked: true), now: now).hasPrefix("Withdrawn "))
        XCTAssertEqual(AgentsReadView.scope(grant("cursor", expires: 1, types: ["screen_text", "activity"])), "standard · screen text, activity · up to 100 a read")
        XCTAssertEqual(AgentsReadView.summary(line("2026-10-14", "cursor", "search", rows: 3, types: ["screen_text": 2, "audio_transcript": 1])),
                       "2 reads, 3 items: 2 screen text, 1 audio transcript")
        XCTAssertEqual(AgentsReadView.summary(line("2026-10-14", "cursor", "index", rows: 1800, types: ["screen_text": 1800])),
                       "2 reads, \(1800.formatted()) items, into its search index on this Mac")

        let days = AgentsReadView.days([line("2026-10-14", "a", "search", rows: 1, types: [:]), line("2026-10-14", "b", "now", rows: 1, types: [:]),
                                        line("2026-10-13", "a", "recent", rows: 1, types: [:])])
        XCTAssertEqual(days.map(\.day), ["2026-10-14", "2026-10-13"])
        XCTAssertEqual(days[0].lines.map(\.clientId), ["a", "b"])
        XCTAssertEqual(AgentsReadView.name("claude-code"), "Claude Code")

        // Many withdrawn grants never hide an older one still active.
        let old = grant("cursor", expires: 86_400)
        let withdrawn = (0..<50).map { grant("claude-code-\($0)", expires: 86_400, revoked: true) }
        let (active, history) = AgentsReadView.split(withdrawn + [old], now: now)
        XCTAssertEqual(active.map(\.grantId), [old.grantId])
        XCTAssertEqual(history.count, 50)
        XCTAssertEqual(AgentsReadView.short("grn_1234567890abcdef"), "grn_12345678")
        XCTAssertEqual(AgentsReadView.name("my-agent"), "my-agent")
    }

    // MARK: Drawing

    /// Each window drawn offscreen, in light and dark. With PRESENCE_CAPTURE_RENDER_DIR set, the
    /// pictures are kept there, for a look without running the app.
    @MainActor
    func testTheWindowsDraw() throws {
        let snapshot = AgentsReadView.Snapshot(
            grants: [grant("claude-code", expires: 29 * 86_400), grant("cursor", expires: 3600, revoked: true)],
            egress: [line("2026-10-14", "claude-code", "search", rows: 12, types: ["screen_text": 9, "audio_transcript": 3]),
                     line("2026-10-14", "claude-code", "index", rows: 1800, types: ["screen_text": 1500, "activity": 300]),
                     line("2026-10-13", "claude-code", "now", rows: 4, types: ["activity": 2, "screen_text": 2])])
        let views: [(String, AnyView)] = [
            ("agents-read", AnyView(AgentsReadView(load: { snapshot }, revoke: { _ in }).frame(width: 600, height: 460))),
            // Drawn on their own: an offscreen drawing leaves a ScrollView's content out.
            ("agents-read-list", AnyView(AgentsReadView.ReadsList(egress: snapshot.egress).padding(20).frame(width: 600))),
            ("agents-read-grants", AnyView(AgentsReadView.GrantsList(grants: snapshot.grants, withdraw: { _ in }).padding(20).frame(width: 600))),
            ("onboarding", AnyView(OnboardingView(permissions: { Permissions(screen: true, microphone: false, accessibility: false) }, canHear: true, hearing: { false },
                                                  allowScreen: {}, allowMicrophone: {}, allowAccessibility: {}, connect: { _ in }, done: {}))),
        ]
        let keep = ProcessInfo.processInfo.environment["PRESENCE_CAPTURE_RENDER_DIR"]
        for (name, view) in views {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).background(scheme == .dark ? Color.black : Color.white))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage, "\(name) didn't draw")
                XCTAssertGreaterThan(image.size.width, 100)
                if let keep, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: keep).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
