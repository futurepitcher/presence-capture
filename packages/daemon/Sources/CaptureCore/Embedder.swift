import Foundation
import NaturalLanguage

/// Text to vectors on this Mac, with Apple's sentence embedding (ADR 0004): nothing leaves it. A
/// text is cut into chunks of a few sentences' length, and each becomes a vector scaled to length
/// one, so cosine similarity is a dot product. The daemon embeds captures with it (ADR 0008 §5); a
/// reader embeds only the query, with the same model, so the two are comparable.
///
/// The sentence embedding, not the contextual one the plan first named: mean-pooled contextual
/// token vectors put unrelated texts nearer than related ones (EmbedderTests' pairs), where the
/// sentence embedding, trained for exactly this, didn't.
public final class Embedder: @unchecked Sendable {
    private let model: NLEmbedding
    private let lock = NSLock()

    /// Words in a chunk: about a short paragraph, which a sentence embedding still holds well.
    public static let wordsPerChunk = 60

    /// The model's identity, kept with every vector: vectors from another model aren't comparable.
    public let modelIdentifier: String
    public var dimension: Int { model.dimension }

    /// The sentence embedding for `language`; nil when this Mac has none for it.
    public init?(language: NLLanguage = .english) {
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.model = model
        modelIdentifier = "apple-sentence-\(language.rawValue)-r\(model.revision)"
    }

    /// One unit vector per chunk of `text`; none for text with no words.
    public func embed(_ text: String) -> [[Float]] {
        Self.chunks(text).compactMap { chunk in lock.withLock { model.vector(for: chunk) }.map(Self.unit) }
    }

    /// The text's words, `wordsPerChunk` at a time.
    static func chunks(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        return stride(from: 0, to: words.count, by: wordsPerChunk).map { words[$0..<min($0 + wordsPerChunk, words.count)].joined(separator: " ") }
    }

    /// Scaled to length one; all zeros stays zeros.
    public static func unit(_ vector: [Double]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { length == 0 ? 0 : Float($0 / length) }
    }

    /// Cosine similarity of two unit vectors.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
