# ADR 0008: Recall indexes live in memory; at rest, everything is sealed

## Status

**Proposed** — 2026-10-10. Shapes M3 (search, vectors, sessions, `pcap-mcp`).

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

1. **At rest, everything derived is sealed.** Embeddings, session labels and
   digests are projection outputs (migration 006): sealed under their source
   capture's key, erased by its revocation, and covered by the forensic check.
   No index of content is ever written to disk.

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

4. **The daemon writes; `pcap-mcp` reads.** The native MCP server is the
   reader: a separate process in the app bundle, launched by an MCP client
   over stdio. It opens the store read-only and gets the master key from the
   Keychain, whose item lists both the app and `pcap-mcp` as trusted. It
   holds the indexes, serves `search`, `timeline`, `now`, `session` and
   `transcript` through grants, the envelope and the egress log (ADR 0001),
   and hosts projector plugins (ADR 0007).

5. **Embeddings are computed by the daemon**, as a first-party projector
   (`NLContextualEmbedding`, ADR 0004), and stored sealed. The reader loads
   them; it never computes them for stored content. It embeds only the query.

## Consequences

- **Nothing to erase on disk but the sealed store**, so the forensic check
  keeps covering everything.
- **Cold start costs time**: a reader unseals what it indexes when it starts.
  The M3 eval measures it at 30 days of data, against a target to be set
  there. If it's too slow, the fix is a faster unseal or a smaller window,
  never an index on disk.
- **Memory is spent in the reader, not the daemon**, so the daemon's 250 MB
  budget is untouched. Vectors can drop to float16 if the eval says so.
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
