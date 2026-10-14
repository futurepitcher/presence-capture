import XCTest
@testable import CaptureStore

final class MemoryIndexTests: XCTestCase {
    /// What a reader unseals into memory stays there: a sort too big for the page cache would
    /// otherwise spill to a temporary file, outside the store and beyond revocation.
    func testKeepsItsTemporaryStorageInMemory() {
        XCTAssertEqual(MemoryIndex().rows("PRAGMA temp_store").first?.first as? Int, 2, "temp_store isn't MEMORY")
    }
}
