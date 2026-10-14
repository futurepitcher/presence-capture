import CaptureCore
@testable import CaptureRecall
@testable import CaptureStore
import XCTest

final class VectorsTests: XCTestCase {
    func testKeepsAVectorCloseToItselfInAboutSevenHundredBytes() throws {
        let vector = Embedder.unit((0..<512).map { sin(Double($0)) })
        let json = Vectors.encode(vector, model: "m")
        XCTAssertLessThan(json.count, 800)
        let (model, back) = try XCTUnwrap(Vectors.decode(String(decoding: json, as: UTF8.self)))
        XCTAssertEqual(model, "m")
        // Quantizing to a byte a component moves cosine similarity by about a thousandth.
        XCTAssertGreaterThan(Embedder.similarity(vector, back), 0.995)
        XCTAssertNil(Vectors.decode("{\"model\":\"m\"}"))
    }
}

final class FusionTests: XCTestCase {
    func testRanksFirstWhatBothListsRankHigh() {
        XCTAssertEqual(Fusion.reciprocalRank([["a", "b", "c"], ["b", "a", "d"]]).prefix(2), ["a", "b"])
        XCTAssertEqual(Fusion.reciprocalRank([["x"], ["y", "x"]]).first, "x")
        XCTAssertEqual(Fusion.reciprocalRank([[], []]), [])
    }
}

final class EmbeddingProjectorTests: XCTestCase {
    private func store() throws -> (CaptureStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey()), dir)
    }

    private func screen(_ store: CaptureStore, _ text: String, level: String = "standard") throws -> String {
        try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", privacyLevel: level, contentText: text))
    }

    /// What its grant admits is embedded, sealed under each capture's key; nothing else is; nothing is
    /// read when there's nothing new; and revoking a capture takes its vectors with it.
    func testEmbedsWhatItsGrantAdmitsAndNothingElse() throws {
        guard let embedder = Embedder() else { throw XCTSkip("no English sentence embedding on this Mac") }
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try screen(store, "we agreed to ship the release on friday")
        let private_ = try screen(store, "my bank balance", level: "sensitive")
        let withheld = try screen(store, "withheld from derived use", level: "excluded")
        try store.append(NewCapture(capturedAt: Date(), captureType: "activity", source: "activity", contentText: "{\"state\":\"active\"}"))
        let projector = try EmbeddingProjector(store: store, embedder: embedder)

        XCTAssertEqual(try projector.run(), 2)
        let embedded = Set(try store.rows("SELECT capture_id FROM projection_entry WHERE output_kind = 'vector'").map { $0.text(0) })
        XCTAssertEqual(embedded, [plain, private_], "embedded what its grant doesn't admit, or missed what it does")
        XCTAssertFalse(embedded.contains(withheld))

        let reads = { try store.rows("SELECT COUNT(*) FROM egress_record WHERE tool = ?", EmbeddingProjector.consumer).first?.int(0) ?? 0 }
        let before = try reads()
        XCTAssertEqual(try projector.run(), 0)
        XCTAssertEqual(try reads(), before, "read, and recorded a read, with nothing new")

        try store.revoke(scopeKind: "capture", scopeValue: plain)
        XCTAssertEqual(try store.rows("SELECT COUNT(*) FROM projection_entry WHERE capture_id = ?", plain).first?.int(0), 0)
    }

    /// Search by meaning: the words of the question appear in no capture, and the one it's about is
    /// found first; a reader without the embedder, searching by keyword alone, doesn't find it.
    func testFindsByMeaningWhatNoKeywordMatches() throws {
        guard let embedder = Embedder() else { throw XCTSkip("no English sentence embedding on this Mac") }
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let release = try screen(store, "we agreed to ship the release on friday")
        _ = try screen(store, "my cat likes tuna for dinner")
        _ = try screen(store, "the quarterly revenue grew by ten percent")
        try EmbeddingProjector(store: store, embedder: embedder).run()
        var grant = NewGrant(clientId: "agent", expiresAt: Date().addingTimeInterval(3600))
        grant.privacyLevels = ["standard"]
        let grantId = try store.issueGrant(grant)

        let question = ["query": "launch date"]
        let found = try Recall(store: store, grantId: grantId, embedder: embedder).call("search", question)
        XCTAssertEqual(Self.ids(found).first, release)
        XCTAssertEqual(Self.ids(try Recall(store: store, grantId: grantId).call("search", question)), [], "keyword search found it without the words")
    }

    private static func ids(_ answer: CanonicalJSON) -> [String] {
        ((answer.foundation as? [[String: Any]]) ?? []).compactMap {
            (($0["presence_capture_untrusted"] as? [String: Any])?["provenance"] as? [String: Any])?["capture_id"] as? String
        }
    }
}
