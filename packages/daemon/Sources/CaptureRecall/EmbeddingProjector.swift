import CaptureCore
import CaptureStore
import Foundation

/// The first-party embedding projector (ADR 0008 §5): the daemon embeds what's captured, on this Mac,
/// and keeps each vector sealed under its capture's own key, so revoking the capture erases it.
///
/// It reads through a grant of its own, so the store decides what it may embed and records every
/// capture it read (egress, `projector:embeddings`): screen text and transcripts at the standard and
/// sensitive levels, never excluded or sacred ones. A reader is served the vectors of only what its
/// own grant admits.
public final class EmbeddingProjector: @unchecked Sendable {
    public static let projection = "embeddings"
    public static let consumer = "projector:embeddings"
    /// Captures embedded in one run, at most.
    public static let batch = 50

    private let store: CaptureStore
    private let embedder: Embedder
    private let lock = NSLock()

    public init(store: CaptureStore, embedder: Embedder) throws {
        (self.store, self.embedder) = (store, embedder)
        try store.registerProjection(name: Self.projection, kind: "vector")
    }

    /// Embeds up to one batch of what's been captured since the last run, and returns how many
    /// captures it embedded. Nothing is read, or recorded as read, when there's nothing new.
    @discardableResult
    public func run() throws -> Int {
        try lock.withLock {
            let after = try store.watermark(consumer: Self.consumer)
            let latest = try store.latestSequence()
            guard latest > after else { return 0 }
            let envelopes = try store.read(grantId: try grant(), ReadRequest(tool: Self.consumer, query: Self.projection,
                                                                              limit: Self.batch, afterSequence: after))
            var embedded = 0
            var through = after
            for envelope in envelopes {
                let inner = (envelope.foundation as? [String: Any])?["presence_capture_untrusted"] as? [String: Any] ?? [:]
                let provenance = inner["provenance"] as? [String: Any] ?? [:]
                guard let id = provenance["capture_id"] as? String, let sequence = (provenance["sequence"] as? NSNumber)?.intValue else { continue }
                let outputs = embedder.embed(inner["content"] as? String ?? "").enumerated().map {
                    (ref: "v:\($0.offset)", kind: Vectors.kind, json: Vectors.encode($0.element, model: embedder.modelIdentifier))
                }
                do {
                    try store.recordProjection(projection: Self.projection, captureId: id, outputs: outputs, consumer: Self.consumer, sequence: sequence)
                    if !outputs.isEmpty { embedded += 1 }
                } catch StoreError.revoked {
                    // Revoked while it was embedded: nothing is kept for it, and the watermark moves on.
                    try store.setWatermark(consumer: Self.consumer, sequence: sequence)
                }
                through = sequence
            }
            // A short page read everything the grant admits up to `latest`: what it skipped (activity,
            // excluded captures) is passed over, so it isn't asked for again.
            if envelopes.count < Self.batch { try store.setWatermark(consumer: Self.consumer, sequence: max(latest, through)) }
            return embedded
        }
    }

    /// The grant it reads through: the one in force, or a new one, a year at a time.
    private func grant() throws -> String {
        if let id = try store.grantInForce(clientId: Self.consumer) { return id }
        var grant = NewGrant(clientId: Self.consumer, expiresAt: Date().addingTimeInterval(365 * 86_400))
        grant.privacyLevels = ["standard", "sensitive"]
        grant.captureTypes = ["screen_text", "audio_transcript"]
        grant.maxRowsPerQuery = Self.batch
        return try store.issueGrant(grant)
    }
}
