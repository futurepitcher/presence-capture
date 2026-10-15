@testable import CaptureStore
import CryptoKit
import Foundation
import XCTest

/// R8 for what's heard: speech is kept only if said since the exclusion list was last readable.
final class ReadableSinceTests: XCTestCase {
    func testSpeechFromWhileTheListCouldntBeReadNeverGetsIn() {
        let t0 = Date()
        let at = { (s: TimeInterval) in t0.addingTimeInterval(s) }
        let readable = ReadableSince()
        XCTAssertFalse(readable.admits(at(0)), "nothing is admitted before the list has been read")
        readable.observe(true, at: at(0))
        XCTAssertTrue(readable.admits(at(1)))
        readable.observe(true, at: at(5))
        XCTAssertTrue(readable.admits(at(1)), "a readable list read again doesn't move the start")
        readable.observe(false, at: at(10))
        XCTAssertFalse(readable.admits(at(1)), "while it can't be read, nothing is kept, however early it was said")
        readable.observe(true, at: at(20))
        XCTAssertFalse(readable.admits(at(12)), "said while it couldn't be read, delivered after")
        XCTAssertFalse(readable.admits(at(1)), "said before the break, delivered after it")
        XCTAssertTrue(readable.admits(at(21)))
    }
}

/// What the store makes on disk is its owner's alone.
final class StoreFolderTests: XCTestCase {
    func testAFolderTheStoreMakesIsItsOwnersAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("home")
        let store = try CaptureStore(path: folder.appendingPathComponent("store.sqlite").path, masterKey: SymmetricKey(size: .bits256))
        store.close()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path))[.posixPermissions] as? Int, 0o700)
    }

    func testAStoreLeftReadableByOthersIsMadePrivateWhenOpened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("home")
        let path = folder.appendingPathComponent("store.sqlite").path
        let key = SymmetricKey(size: .bits256)
        try CaptureStore(path: path, masterKey: key).close()
        // As an earlier build, or a copy, left it: readable by every account.
        for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let store = try CaptureStore(path: path, masterKey: key)
        defer { store.close() }
        for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file))[.posixPermissions] as? Int, 0o600, file)
        }
        CaptureStore.makePrivate(folder.path, mode: 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path))[.posixPermissions] as? Int, 0o700)
    }
}

/// A writer that waits for the store says, once it has it, whether it still may write.
final class AppendAdmissionTests: XCTestCase {
    func testAWriteThatWaitedIsntMadeIfItsNoLongerAdmitted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path
        let key = SymmetricKey(size: .bits256)
        let store = try CaptureStore(path: path, masterKey: key)
        let other = try CaptureStore(path: path, masterKey: key)
        // Another writer holds the store; a capture's write waits behind it.
        try other.exec("BEGIN IMMEDIATE")
        let admitted = Locked(true)
        let finished = expectation(description: "the write gave up")
        var outcome: Error?
        DispatchQueue.global().async {
            do {
                _ = try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "shown after Pause"),
                                     admit: { admitted.value })
            } catch {
                outcome = error
            }
            finished.fulfill()
        }
        // Paused (and let go again, even) while it waited: its moment is no longer admitted.
        usleep(200_000)
        admitted.value = false
        try other.exec("COMMIT")
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(outcome as? StoreError, .notAdmitted)
        XCTAssertEqual(try store.rows("SELECT COUNT(*) FROM capture_event").first?.int(0), 0, "written after it stopped being admitted")
    }
}

/// A value read and written from any thread, for tests.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
