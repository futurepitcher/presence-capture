import XCTest
@testable import CaptureStore

final class MemoryIndexTests: XCTestCase {
    /// What a reader unseals into memory stays there: a sort too big for the page cache would
    /// otherwise spill to a temporary file, outside the store and beyond revocation.
    func testKeepsItsTemporaryStorageInMemory() {
        XCTAssertEqual(MemoryIndex().rows("PRAGMA temp_store").first?.first as? Int, 2, "temp_store isn't MEMORY")
    }
}

final class TextWithNULTests: XCTestCase {
    /// Text holding a NUL is kept whole: bound by its length, read back by its length.
    func testKeepsTextWithANULWholeInMemory() {
        let memory = MemoryIndex()
        memory.exec("CREATE VIRTUAL TABLE words USING fts5(content)")
        memory.run("INSERT INTO words (content) VALUES (?)", "alpha\u{0}release")
        XCTAssertEqual(memory.rows("SELECT content FROM words").first?.first as? String, "alpha\u{0}release")
        XCTAssertEqual(memory.rows("SELECT content FROM words WHERE words MATCH 'release'").count, 1, "the text after the NUL wasn't indexed")
    }

    func testKeepsMetadataWithANULWholeInTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        let id = try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", sourceApp: "odd\u{0}app", contentText: "x"))
        XCTAssertEqual(try store.rows("SELECT source_app FROM capture_event WHERE capture_id = ?", id).first?.optionalText(0), "odd\u{0}app")
    }
}
