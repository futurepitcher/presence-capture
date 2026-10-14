import Foundation
import XCTest
@testable import CaptureStore

/// The rules applied before disk, held to packages/schema/cases, as the reference is.
final class SharedCasesTests: XCTestCase {
    private func cases(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../schema/cases/\(name).json").standardizedFileURL
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testComputesSessionsAsTheCasesSay() throws {
        for c in try XCTUnwrap(cases("sessions")["cases"] as? [[String: Any]]) {
            let activity = try XCTUnwrap(c["activity"] as? [[String: Any]]).map {
                Sessions.Activity(id: $0["id"] as! String, at: $0["at"] as! String, state: $0["state"] as! String,
                                  app: $0["app"] as? String, window: $0["window"] as? String, excluded: $0["excluded"] as? Bool ?? false)
            }
            let expected = try XCTUnwrap(c["sessions"] as? [[String: Any]]).map {
                Sessions.Session(id: $0["id"] as! String, startedAt: $0["started_at"] as! String,
                                 endedAt: $0["ended_at"] as? String, captureIds: $0["capture_ids"] as! [String])
            }
            XCTAssertEqual(Sessions.of(activity, now: c["now"] as! String), expected, c["why"] as? String ?? "")
        }
    }

    func testHoldsTheSharedBuiltInLists() throws {
        let file = try cases("exclusion")
        XCTAssertEqual((file["system_apps"] as? [String: [String]])?["macos"], Exclusion.systemApps)
        XCTAssertEqual(file["self_windows"] as? [String], Exclusion.selfWindows)
    }

    func testParsesTheUsersListAsTheCasesSay() throws {
        for c in try XCTUnwrap(cases("exclusion")["parse"] as? [[String: Any]]) {
            XCTAssertEqual(Exclusion.parse(c["text"] as? String ?? ""), c["fragments"] as? [String])
        }
    }

    func testExcludesWhatTheCasesSay() throws {
        for c in try XCTUnwrap(cases("exclusion")["cases"] as? [[String: Any]]) {
            let excluded = Exclusion.isExcluded(app: c["app"] as? String ?? "", window: c["window"] as? String ?? "",
                                                fragments: c["fragments"] as? [String] ?? [])
            XCTAssertEqual(excluded, c["excluded"] as? Bool, c["why"] as? String ?? "")
        }
    }

    func testReadsNoListAsEmptyAndAnUnreadableOneAsNone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(Exclusion.load(dir.appendingPathComponent("missing.txt").path), [])
        let unreadable = dir.appendingPathComponent("list.txt")
        try "Signal\n".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        XCTAssertNil(Exclusion.load(unreadable.path), "an unreadable list was taken for an empty one")
    }

    func testRedactsWhatTheCasesSay() throws {
        for c in try XCTUnwrap(cases("redaction")["cases"] as? [[String: Any]]) {
            let out = Redact.redact(c["input"] as? String ?? "")
            if let expected = c["output"] as? String { XCTAssertEqual(out, expected, c["name"] as? String ?? "") }
            for leak in c["must_not_contain"] as? [String] ?? [] {
                XCTAssertFalse(out.contains(leak), "leaked \(leak): \(out)")
            }
        }
    }

    func testRedactsALongRunInLinearTime() {
        let started = Date()
        for run in [String(repeating: "x", count: 400_000), String(repeating: "7", count: 400_000), String(repeating: "a1.", count: 130_000)] {
            XCTAssertEqual(Redact.redact(run), run)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "redaction runs in the capture path")
    }
}
