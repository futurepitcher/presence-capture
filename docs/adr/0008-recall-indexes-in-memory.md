# ADR 0008: Recall indexes live in memory; at rest, everything is sealed

## Status

**Accepted** — 2026-10-10. Shapes M3 (search, vectors, sessions, `pcap-mcp`).
**Amended** — 2026-10-14: 0.1 ships keyword search alone; embeddings wait for
a model that measures better (§5).

The eval (`packages/schema/bin/eval.js`) was run on a 30-day store of 18,036
captures, with 50 questions, 25 of them asked in words the answer doesn't use.

| Ranking | Recall@5 |
|---|---|
| Keyword (BM25) alone | 40/50 |
| Apple's on-device embeddings alone | 15/50, and 1 of the 25 paraphrased questions |
| The two fused | 37/50 |

Ordinary text scored 0.5–0.65 against nearly any question, above the real
answers. Mean-pooled `NLContextualEmbedding` was worse still on paraphrase
pairs (`EmbedderTests`), so the sentence embedding was the one measured.

So 0.1 runs no embedding projector and keeps no vectors: they would cost
storage and CPU for a worse answer. The store's side (sealed projection
outputs, `output_sequence`, `readOutputs`) is in place. The projector, the
quantized vector format and fusion are kept on the branch
`wip/embeddings-0.2`, for a stronger open on-device model (Core ML), shipped
only if it beats keyword search on this eval.

## Context

M3 adds recall: keyword and semantic search, a timeline, "what am I doing
now", and activity sessions. The plan said full-text search would be an SQLite
FTS5 table on disk. That breaks the project's central guarantee:

- **An FTS index stores every word in plain text, on disk** (its `%_data` and
  `%_content` shadow tables), for every capture, revoked or not. R11 requires
  that plaintext never reaches disk, and the forensic check would fail the
  first indexed capture.
- **Deleting from FTS5 doesn't remove the words.** A delete is recorded as a
  tombstone in a new segment; the old segment keeps the terms until a merge.
  Revocation couldn't prove anything was gone.
- **Embeddings leak too.** Inversion attacks recover much of a text from its
  embedding, so a plain vector column is plaintext with extra steps.
- Encrypting the whole database (SQLCipher) hides the words from someone
  without the key. But a revoked capture's terms stay in encrypted pages that
  the master key still opens, which fails R11's "can't be recovered with the
  master key".

## Decision

1. **At rest, everything derived is sealed, and only what one capture
   answers for is kept.**
   - An output derived from exactly one capture (its embedding, its summary)
     is a projection output (migration 006). It's sealed under that capture's
     key, erased by its revocation, and covered by the forensic check.
   - An output derived from several captures is never written to disk. That
     covers a session, its label, and a day's digest. Sealed under one
     capture's key, it would survive the revocation of any of the others,
     which breaks R10. Instead it's computed in memory, and recomputed from
     what remains when any capture behind it is revoked.
   - Persisting a multi-capture output needs an RFC: a list of its sources,
     and a key of its own destroyed by the revocation of any of them.
   - No index of content is ever written to disk.

2. **Indexes live in the memory of the process that reads**:
   - keyword search: SQLite FTS5 in `:memory:`, BM25;
   - vectors: an in-memory array searched by cosine;
   - sessions: built from activity captures.

   The reader builds them at start by unsealing what its grant admits, and
   keeps them current by watermark (`sequence`).

3. **Revocation reaches memory, and doesn't depend on it.** The reader watches
   `revocation` by sequence and evicts revoked captures from its indexes.
   Independently, every result is filtered against `revoked_capture` and the
   grant in the store before it's served, and a revoked capture's content
   can't be unsealed anyway, because its key is gone. An eviction that lags
   can't serve anything.

4. **The daemon writes captures; `pcap-mcp` reads them, and writes only its
   own accounting.**
   - The native MCP server is a separate process in the app bundle, launched
     by an MCP client over stdio. It gets the master key from the Keychain,
     whose item lists both the app and `pcap-mcp` as trusted. (Amended
     2026-10-14: and `pcap`, the admin CLI that issues grants and Forgets.)
   - It holds the indexes, and serves `search`, `timeline`, `now`, `session`
     and `transcript` through grants and the envelope. (Amended 2026-10-14:
     and `recent`, the newest captures.)
   - ADR 0001 requires every served row to be recorded in the egress log, so
     `pcap-mcp` opens the store writable, under an **SQLite authorizer that
     refuses every write except an insert into `egress_record`**. The log's
     triggers already refuse updates and deletes. The boundary is enforced by
     SQLite, below any tool handler, as grants are: a `pcap-mcp` bug can't
     change a capture, a key or a grant.

5. **Projectors run in the daemon, the writer.**
   - Embeddings are computed by the daemon, as a first-party projector
     (`NLContextualEmbedding`, ADR 0004), and stored sealed. The reader loads
     them; it embeds only the query.
   - Projector plugins (ADR 0007) are hosted by the daemon too, in a helper
     process it can kill at a capture's time limit. The helper never opens
     the store.
   - The daemon reads for a projector through the projector's grant, so
     every capture is enveloped and egress-logged under `projector:<name>`.
   - It commits each capture's outputs and the projector's watermark in one
     transaction (`recordProjection`).
   - The daemon still serves no client. A projector is a sandboxed function
     it calls, whose every read is accounted.

## Consequences

- **Nothing to erase on disk but the sealed store**, so the forensic check
  keeps covering everything.
- **Cold start costs time**: a reader unseals what it indexes when it starts.
  The M3 eval measures it at 30 days of data, against a target to be set
  there. If it's too slow, the fix is a faster unseal or a smaller window,
  never an index on disk.
- **Memory is spent in the reader, not the daemon**, so the daemon's 250 MB
  budget is untouched. Vectors can drop to float16 if the eval says so.
- **Sessions and digests are recomputed, not stored.** That's cheap for
  sessions (activity is small). A digest from Foundation Models costs
  seconds, so it's computed on request and cached in memory until a capture
  behind it is revoked.
- **The swap file is macOS's to protect**: it's encrypted by default on Apple
  Silicon. The reader never writes an index itself.
- **A store too large for memory needs another design.** Blind indexing
  (keyed hashes of terms) is the candidate, with its leaks stated. It isn't
  needed at personal scale with retention.

## Alternatives

| Option | Why not |
|--------|---------|
| FTS5 on disk, with `secure_delete` and `optimize` after each revoke | Plaintext at rest for every live capture; segments keep terms until merged |
| SQLCipher for the whole database | A dependency, and revoked terms stay recoverable with the master key |
| Blind index (HMAC of each term) on disk | No prefix or fuzzy matching; leaks term frequencies. Kept as the plan for stores that outgrow memory |
| Embeddings in a plain vector column | Embeddings can be inverted to approximate their text |
