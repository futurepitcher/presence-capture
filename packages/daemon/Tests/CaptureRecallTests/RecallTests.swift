@testable import CaptureRecall
@testable import CaptureStore
import XCTest

final class RecallTests: XCTestCase {
    /// Search serves as many results as asked for, within the grant's cap: not a fixed shortlist.
    func testServesAsManySearchResultsAsAskedForWithinTheGrant() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(path: dir.appendingPathComponent("store.sqlite").path, masterKey: Seal.newKey())
        for i in 0..<75 {
            try store.append(NewCapture(capturedAt: Date(), captureType: "screen_text", source: "screen", contentText: "note number \(i)"))
        }
        var grant = NewGrant(clientId: "agent", expiresAt: Date().addingTimeInterval(3600))
        grant.maxRowsPerQuery = 100
        let recall = Recall(store: store, grantId: try store.issueGrant(grant))
        XCTAssertEqual((try recall.call("search", ["query": "note", "limit": 75]).foundation as? [Any])?.count, 75)
        XCTAssertEqual((try recall.call("search", ["query": "note"]).foundation as? [Any])?.count, 10, "the default limit")
    }
}
