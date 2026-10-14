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
}
