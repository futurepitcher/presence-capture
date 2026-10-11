import Foundation
import XCTest
@testable import CaptureStore

final class PinsTests: XCTestCase {
    func testRunsOnlyAsApprovedAndNotOnceAScriptChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("sensor.mjs")
        try "console.log('{}')".write(to: script, atomically: true, encoding: .utf8)
        let command = ["/bin/sh", script.path, "--once", dir.path]

        let pins = try Pins.compute(command)
        XCTAssertEqual(Set(pins.keys), ["/bin/sh", script.path], "the executable and the script, not the directory it watches")
        XCTAssertNil(Pins.error(command, approved: pins))
        XCTAssertEqual(Pins.error(command, approved: nil), "not approved")

        try "console.log('swapped')".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(Pins.error(command, approved: pins), "\(script.path) has changed since it was approved")
        XCTAssertThrowsError(try Pins.compute(["sh", script.path]))
    }

    func testPinsARelativeOrFlaggedScriptAndNotADeviceAsTheReferenceDoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one".write(to: dir.appendingPathComponent("sensor.mjs"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let command = ["/bin/sh", "sensor.mjs", "--config=\(dir.appendingPathComponent("config.json").path)", "--quiet", "/dev/null"]

        let pins = try Pins.compute(command, cwd: dir.path)
        XCTAssertEqual(Set(pins.keys), ["/bin/sh", dir.appendingPathComponent("sensor.mjs").path, dir.appendingPathComponent("config.json").path],
                       "the relative script and the --flag=path file are pinned; /dev/null is not even read")
        try "two".write(to: dir.appendingPathComponent("sensor.mjs"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(Pins.error(command, approved: pins, cwd: dir.path), "a relative script was swapped without re-approval")
    }

    func testFollowsASymlinkToWhatRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("node-1.0")
        try "v1".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let pins = try Pins.compute([link.path])
        XCTAssertEqual(Array(pins.keys), [link.path])
        try "v2".write(to: real, atomically: true, encoding: .utf8)
        XCTAssertNotNil(Pins.error([link.path], approved: pins), "an upgraded interpreter behind a symlink ran without re-approval")
    }
}
