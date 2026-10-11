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
}
