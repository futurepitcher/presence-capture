import XCTest
@testable import CaptureCore

final class EmbedderTests: XCTestCase {
    func testCutsTextIntoChunksTheModelTakesWhole() {
        XCTAssertEqual(Embedder.chunks("  "), [])
        XCTAssertEqual(Embedder.chunks("one two\nthree"), ["one two three"])
        let long = (0..<(Embedder.wordsPerChunk * 2 + 1)).map { "w\($0)" }.joined(separator: " ")
        let chunks = Embedder.chunks(long)
        XCTAssertEqual(chunks.map { $0.split(separator: " ").count }, [Embedder.wordsPerChunk, Embedder.wordsPerChunk, 1])
    }

    func testScalesToLengthOne() {
        let v = Embedder.unit([3, 4])
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(Embedder.unit([0, 0]), [0, 0])
        XCTAssertEqual(Embedder.similarity(v, v), 1, accuracy: 1e-6)
    }

    /// Meaning, not words: in each pair the second text says what the first does in other words, and
    /// the third is about something else. Skipped where this Mac has no English sentence embedding.
    func testPlacesTextsAboutTheSameThingNearerEachOther() throws {
        guard let embedder = Embedder() else { throw XCTSkip("no English sentence embedding on this Mac") }
        let cases = [
            ("we agreed to ship the release on friday", "the launch is scheduled for the end of the week", "my cat likes tuna for dinner"),
            ("the build failed because of a missing dependency", "compilation broke, a package could not be found", "we went hiking in the mountains"),
            ("book a table for two at the italian place", "reserve dinner at the pasta restaurant", "the quarterly revenue grew by ten percent"),
            ("how do I reset my password", "I forgot my login credentials", "the weather will be sunny tomorrow"),
            ("the meeting moved to thursday afternoon", "we rescheduled the call to later this week", "she plays the violin in an orchestra"),
        ]
        for (text, same, other) in cases {
            let (a, b, c) = (try XCTUnwrap(embedder.embed(text).first), try XCTUnwrap(embedder.embed(same).first), try XCTUnwrap(embedder.embed(other).first))
            XCTAssertEqual(a.count, embedder.dimension)
            XCTAssertGreaterThan(Embedder.similarity(a, b), Embedder.similarity(a, c), text)
        }
    }
}
