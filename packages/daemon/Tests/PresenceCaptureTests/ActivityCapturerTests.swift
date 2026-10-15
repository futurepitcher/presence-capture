@testable import CaptureStore
import CryptoKit
import Foundation
@testable import PresenceCapture
import XCTest

final class ActivityCapturerTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        var lines: [String] { lock.withLock { all } }
        func write(_ line: String) { lock.withLock { all.append(line) } }
    }

    /// While the app and window are being read, the person forgets the last minute from another
    /// process. What was read is stamped when it was seen, inside the minute forgotten, so the store
    /// refuses it; stamped when it's written, it would land after the Forget and be kept.
    func testWhatsReadWhileItsForgottenIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let key = SymmetricKey(size: .bits256)
        let store = try CaptureStore(path: path, masterKey: key)
        let forgetter = try CaptureStore(path: path, masterKey: key)
        let log = Lines()
        var forgetWhileReading = true
        let capturer = ActivityCapturer(store: store, log: log.write) {
            if forgetWhileReading {
                let now = Date()
                do { try forgetter.revoke(scopeKind: "time_range", scopeValue: "\(CaptureStore.iso(now.addingTimeInterval(-60)))/\(CaptureStore.iso(now))") } catch { XCTFail("forget failed: \(error)") }
                // Reading takes a moment more after the Forget lands.
                Thread.sleep(forTimeInterval: 0.02)
            }
            return .init(locked: false, idle: 0, app: ("Notes", "com.apple.Notes"), window: "Plans")
        }

        capturer.tick(fragments: [], seesScreen: true)
        capturer.flush()
        XCTAssertEqual(try store.rows("SELECT COUNT(*) FROM capture_event").first?.int(0), 0, "activity read during a Forget was kept")
        XCTAssertEqual(log.lines, ["append.refused_revoked kind=activity"])

        // The same activity, seen after the Forget, is kept: it was the moment that was refused, not the activity.
        forgetWhileReading = false
        capturer.tick(fragments: [], seesScreen: true)
        capturer.flush()
        XCTAssertEqual(try store.rows("SELECT COUNT(*) FROM capture_event").first?.int(0), 1)
    }

    /// Quitting with a write waiting on a busy store: the main thread isn't held; the app goes once
    /// the write is done.
    func testQuittingNeverWaitsOnTheMainThreadForABusyStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        let capturer = ActivityCapturer(store: store, log: { _ in }) { .init(locked: false, idle: 0, app: ("Notes", "com.apple.Notes"), window: "Plans") }
        let held = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.lock.withLock {
                held.signal()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        held.wait()
        capturer.tick(fragments: [], seesScreen: true)
        let gone = expectation(description: "the app goes")
        let started = Date()
        AppDelegate.finishWriting(activity: capturer, audio: nil, admin: DispatchQueue(label: "admin"), connecting: DispatchGroup()) { gone.fulfill() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "quitting waited on the main thread")
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(try store.rows("SELECT COUNT(*) FROM capture_event").first?.int(0), 1, "the app went before what was noted was written")
    }

    /// Work confirmed before Quit (a Forget queued for the store, a connection under way) is
    /// finished before the app goes.
    func testQuittingWaitsForConfirmedWork() {
        let admin = DispatchQueue(label: "admin"), connecting = DispatchGroup()
        let finished = Flag(), connected = Flag()
        admin.async {
            Thread.sleep(forTimeInterval: 0.4)
            finished.value = true
        }
        connecting.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            connected.value = true
            connecting.leave()
        }
        let gone = expectation(description: "the app goes")
        AppDelegate.finishWriting(activity: nil, audio: nil, admin: admin, connecting: connecting) {
            XCTAssertTrue(finished.value, "the app went before a confirmed Forget was done")
            XCTAssertTrue(connected.value, "the app went during a connection")
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
    }

    func testQuittingWaitsUntilTheSensorsAreGone() {
        let sensors = DispatchGroup()
        let stopped = Flag()
        sensors.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            stopped.value = true
            sensors.leave()
        }
        let gone = expectation(description: "the app goes")
        AppDelegate.finishWriting(activity: nil, audio: nil, admin: DispatchQueue(label: "admin"), connecting: DispatchGroup(), sensors: sensors) {
            XCTAssertTrue(stopped.value, "the app went before its sensors, and what they started, were stopped")
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
    }

    /// The store held for seconds (another writer, or a revocation waiting on SQLite) never holds
    /// up the tick: it runs on the main thread, where locking, sleep and Pause are heard.
    func testATickNeverWaitsForABusyStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        let capturer = ActivityCapturer(store: store, log: { _ in }) { .init(locked: false, idle: 0, app: ("Notes", "com.apple.Notes"), window: "Plans") }
        let held = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.lock.withLock {
                held.signal()
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        held.wait()
        let started = Date()
        capturer.tick(fragments: [], seesScreen: true)
        capturer.reset()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the tick waited for the store")
        capturer.flush()
        XCTAssertEqual(try store.rows("SELECT COUNT(*) FROM capture_event").first?.int(0), 1, "the activity wasn't written once the store was free")
    }
}
