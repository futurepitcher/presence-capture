@testable import CaptureStore
import CryptoKit
import Foundation
@testable import PresenceCapture
import XCTest

/// Sensors run as the person, so stopping them stops all they started: nothing outlives the app.
final class SensorPluginsTests: XCTestCase {
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func testStoppingASensorStopsWhatItStartedBeforeItsDone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A sensor that starts a child of its own, which ignores being told to stop, and waits.
        let pids = dir.appendingPathComponent("pids")
        let script = dir.appendingPathComponent("sensor.sh")
        try """
            trap '' TERM
            sleep 60 &
            echo "$$ $!" > '\(pids.path)'
            wait
            """.write(to: script, atomically: true, encoding: .utf8)
        let config = dir.appendingPathComponent("sensors.json")
        try #"[{"name": "lingering", "command": ["/bin/sh", "\#(script.path)"]}]"#.write(to: config, atomically: true, encoding: .utf8)
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        let sensors = SensorPlugins(configPath: config.path, store: store, fragments: { [] }, held: { false }, log: { _ in })
        sensors.start()
        try sensors.approve("lingering")
        let deadline = Date().addingTimeInterval(5)
        while (try? String(contentsOf: pids, encoding: .utf8))?.split(separator: " ").count != 2, Date() < deadline { usleep(20_000) }
        let started = try String(contentsOf: pids, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        XCTAssertEqual(started.count, 2)
        XCTAssertTrue(started.allSatisfy(alive))

        let stopped = expectation(description: "stopped")
        sensors.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
        // Reaped a moment after it's killed.
        let reaped = Date().addingTimeInterval(2)
        while started.contains(where: alive), Date() < reaped { usleep(20_000) }
        XCTAssertFalse(alive(started[1]), "the child a sensor started outlived it")
        XCTAssertFalse(alive(started[0]), "a sensor that ignored being told to stop outlived it")
    }
}
