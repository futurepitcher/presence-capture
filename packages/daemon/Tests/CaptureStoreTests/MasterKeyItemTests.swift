import XCTest
@testable import CaptureStore

/// The names the app and its readers agree on. The Keychain itself isn't touched here: on a
/// person's Mac a test that reads it can prompt.
final class MasterKeyItemTests: XCTestCase {
    func testReadersAskForTheCurrentVersionAndTheAppUpgradesFromNewestToOldest() {
        XCTAssertEqual(MasterKeyItem.current, "store.shared.v\(MasterKeyItem.version)")
        XCTAssertEqual(MasterKeyItem.older.suffix(2), ["store.shared", "store"])
        XCTAssertEqual(MasterKeyItem.older.count, MasterKeyItem.version + 1, "every earlier version is upgraded from")
        XCTAssertFalse(MasterKeyItem.older.contains(MasterKeyItem.current))
        let versions = MasterKeyItem.older.dropLast(2).compactMap { Int($0.dropFirst("store.shared.v".count)) }
        XCTAssertEqual(versions, versions.sorted(by: >), "newest first")
    }

    func testTheServiceIsNamedAfterTheBundle() {
        XCTAssertEqual(MasterKeyItem.service(bundleIdentifier: "ai.presenceos.capture"), "ai.presenceos.capture.master-key")
        XCTAssertEqual(MasterKeyItem.service(bundleIdentifier: "org.example.fork"), "org.example.fork.master-key")
        XCTAssertEqual(MasterKeyItem.service(bundleIdentifier: nil), "ai.presenceos.capture.master-key")
    }
}
