import CaptureCore
import Foundation

/// How a capture's embedding is kept, as a projection output's JSON (ADR 0008): the model that made
/// it, and its unit vector quantized to one signed byte a component (scaled by 127), in base64. A
/// 512-dimension vector is about 700 bytes, not the 6 KB its numbers would be as text, so a month of
/// screen and speech stays well inside the store's budget; cosine similarity barely moves.
public enum Vectors {
    public static let kind = "vector"

    public static func encode(_ vector: [Float], model: String) -> Data {
        let bytes = vector.map { UInt8(bitPattern: Int8(clamping: Int(($0 * 127).rounded()))) }
        let object: [String: Any] = ["model": model, "q8": Data(bytes).base64EncodedString()]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The model and the unit vector an output holds; nil for anything else.
    public static func decode(_ json: String) -> (model: String, vector: [Float])? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let model = object["model"] as? String, let q8 = (object["q8"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        let raw = q8.map { Double(Int8(bitPattern: $0)) / 127 }
        return (model, Embedder.unit(raw))
    }
}

/// Reciprocal-rank fusion (Cormack et al., 2009): each ranked list gives an id 1 / (k + rank), summed
/// across lists, best first. It needs no scores on a common scale, so BM25 and cosine combine as they
/// are; k = 60 is the usual damping.
public enum Fusion {
    public static func reciprocalRank(_ lists: [[String]], k: Double = 60) -> [String] {
        var score: [String: Double] = [:]
        var first: [String: Int] = [:]
        var order = 0
        for list in lists {
            for (rank, id) in list.enumerated() {
                score[id, default: 0] += 1 / (k + Double(rank + 1))
                if first[id] == nil {
                    first[id] = order
                    order += 1
                }
            }
        }
        // Ties keep the order ids were first seen in, so the result doesn't depend on hashing.
        return score.keys.sorted { (score[$0]!, -first[$0]!) > (score[$1]!, -first[$1]!) }
    }
}
