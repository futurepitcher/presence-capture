# Capture Schema Specification

**Version:** 0.1.0-draft
**Status:** Normative for v0.1. Shape may change until 1.0.0.
**Reference implementation:** [`packages/schema`](../../packages/schema)

## Stability statement

While this document is at `0.x`, any part may change without a migration path.
`1.0.0` will commit to backward compatibility for the event shape and the
revocation semantics; everything else remains advisory.

**Conformance is defined by the suite in
[`packages/schema/conformance`](../../packages/schema/conformance), not by this
prose.** Where the two disagree, the suite is correct and this document is a bug.

Keywords MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Scope

How continuous capture of screen, activity, and ambient audio is recorded such
that the record is append-only and auditable, any part of it can be revoked in a
way that provably propagates to derived data, and reads can be constrained by a
classification the storage layer enforces.

Out of scope: how capture is performed, which OCR or ASR engine is used, how
content is classified, and what a consumer does with the result.

## Requirements

| # | Requirement | Store layer (`conformance/store/`) |
|---|-------------|------------------|
| R1 | Capture events are append-only; payloads are content-addressed and stored apart from metadata | `capture.test.js` |
| R2 | Revocation is a first-class event, never a row delete | `revocation.test.js` |
| R3 | Revocation propagates to projections and vector indices, verifiably | `revocation.test.js`; vector backends: `api/vector-store.test.js` |
| R4 | Replay receipts and watermarks record consumer position; replay is deterministic | reference only: `api/replay.test.js` |
| R5 | Every event carries a privacy level, enforced at read boundaries | `capture.test.js`; read boundary: `api/privacy.test.js` |
| R6 | Classification taxonomy is pluggable | `capture.test.js` |
| R7 | Near-identical frames are deduplicated before persistence | `capture.test.js` |
| R8 | Per-application exclusion is supported at capture time | daemon-side; shared cases in `packages/schema/cases/` |
| R9 | The event shape is platform-neutral | by inspection, and by the store layer holding every implementation to the same files |
| R10 | Derived artifacts — transcripts, alignments, embeddings — are projections subject to R3 | `revocation.test.js` |
| R11 | Revocation erases content: no plaintext ever reaches disk, and a revoked capture's key, text and bytes are gone from every file the store leaves, with a receipt | `erasure.test.js`, `capture.test.js`, `revocation.test.js`; the check itself: `mutation.test.js` |
| R12 | Retention is a scheduled revocation, never a delete | `retention.test.js` |

## Entities

### `capture_payload` (R1)

Metadata for a capture's bulk bytes. The bytes themselves are sealed (R11)
and live in `payload_blob` or a file `storage_uri` names.

| Field | Type | Notes |
|-------|------|-------|
| `payload_hash` | TEXT PK | SHA-256 hex over the **sealed** bytes. Identical plaintext in two captures is sealed under two keys and stored twice, so each can be erased alone ([ADR 0002](../adr/0002-erasable-revocation.md)) |
| `byte_count` | INTEGER | Sealed size |
| `media_type` | TEXT | e.g. `image/heic`, `audio/wav` |
| `storage_uri` | TEXT | Where the bytes live. Implementations MAY use segment-plus-offset form |
| `created_at` | TEXT | ISO 8601 |

### `capture_event` (R1, R5, R6, R7, R9, R10)

| Field | Type | Notes |
|-------|------|-------|
| `capture_id` | TEXT PK | |
| `sequence` | INTEGER UNIQUE | Monotonic. The replay ordering — **not** `captured_at`, which can go backwards |
| `captured_at` | TEXT | ISO 8601 UTC with milliseconds (`2026-10-06T09:00:05.000Z`), always. Times are compared as text, so an implementation MUST write this one form, and MUST read a revocation's `time_range` bounds into it before comparing |
| `capture_type` | TEXT | `screen_frame`, `screen_text`, `audio_segment`, `audio_transcript`, `audio_alignment`, `activity` |
| `source` | TEXT | Source family. Platform-neutral (R9) |
| `source_app` | TEXT NULL | Bundle id or executable where known |
| `source_url` | TEXT NULL | MUST be `NULL` when not establishable. MUST NOT be inferred from content |
| `privacy_level` | TEXT | `standard`, `sensitive`, `excluded`, `sacred_mode` |
| `classification` | TEXT NULL | Opaque to the schema (R6) |
| `payload_hash` | TEXT NULL | FK to `capture_payload` |
| `extraction` | TEXT NULL | `accessibility`, `ocr`, `asr`, `none` |
| `derived_from` | TEXT NULL | FK to `capture_event`. Set on derived artifacts (R10) |
| `dedupe_key` | TEXT NULL | Unique where not null (R7). For an observation a sensor marks with `dedupe` ([ADR 0007](../adr/0007-plugins.md)): hex(HMAC-SHA256(HKDF-SHA256(master key, empty salt, info `presence-capture dedupe`, 32 bytes), source ‖ U+001F ‖ value)). It outlives a revocation, so a revoked observation isn't captured again, and without the master key it says nothing about the value |

Implementations MUST reject UPDATE and DELETE against this table. The reference
implementation enforces this with database triggers rather than application
convention, because a convention is not a guarantee.

The event records *that* something was captured. *What* was captured is never
in it: see the next section.

### `capture_key`, `capture_content`, `payload_blob`, `erasure_receipt` (R11)

Content is sealed per capture and erased by revocation
([ADR 0002](../adr/0002-erasable-revocation.md)).

| Table | Field | Notes |
|-------|-------|-------|
| `capture_key` | `capture_id` PK, `wrapped_key` BLOB, `created_at` | The capture's 32-byte data key, sealed by the master key with AAD `key:<capture_id>`. Write-once |
| `capture_content` | `capture_id` PK, `text_sealed` BLOB, `created_at` | Extracted text sealed by the data key, AAD `text:<capture_id>`. **Attacker-controlled** once unsealed. Write-once |
| `payload_blob` | `payload_hash` PK, `sealed` BLOB | Payload bytes sealed by the data key, AAD `payload:<capture_id>`. An implementation MAY keep them in files instead, sealed the same way |
| `erasure_receipt` | `revocation_id` PK, `applied_at`, `keys_destroyed`, `contents_erased`, `payloads_erased` | Append-only |

**Sealing.** AES-256-GCM, combined form `nonce(12) ‖ ciphertext ‖ tag(16)`,
byte-compatible with CryptoKit's `AES.GCM.SealedBox.combined`. The master key
MUST NOT be written to the store or beside it; on macOS it lives in the
Keychain. A store MUST refuse to open with the wrong master key.

**Erasure.** In the transaction that records a revocation, an implementation
MUST delete the revoked set's sealed payloads, sealed text and keys, and write
one `erasure_receipt`. Before the revocation is reported done, deleted pages
MUST be overwritten (`secure_delete`) and any write-ahead log holding the
earlier frames MUST be checkpointed and truncated. A reader in another process
can hold the log, and SQLite reports that only in the checkpoint's result row.
While it does, the implementation MUST NOT report the erasure done, and MUST
complete it once the log can be truncated. **A revocation with no
erasure receipt is non-conformant.** Plaintext content MUST NOT reach disk at
any time.

### Retention (R12)

Retention is a revocation with `scope_kind = time_range`, from the epoch to
`now − days` inclusive, and `reason = 'retention'`
([ADR 0003](../adr/0003-retention-is-revocation.md)). It cascades, prunes and
erases with receipts like any other. An implementation MUST NOT remove content
by any other means. A run with nothing old enough writes nothing.

### `revocation`, `revoked_capture` (R2, R3, R10)

A revocation names a scope: a single capture, a time range (`from/to`), a source,
or a privacy level. Resolving the scope yields a set of captures, which MUST be
extended transitively through `derived_from` — revoking audio revokes its
transcript, and the alignment derived from that transcript (R10).

`revoked_capture.cascaded` records whether a capture was named directly or
reached through the chain.

Revocations are append-only: a revocation cannot be unmade.

### `projection`, `projection_entry`, `projection_revocation` (R3)

A projection is any derived view — a text index, a vector index, a summary.
Entries are attributable to the capture they came from, which is the only reason
revocation can be *proven* to propagate rather than asserted.

An entry may carry what was derived (migration 006): `output_kind` (`text`,
`vector`, `summary`) and `output_sealed`, sealed under the **source capture's
data key** with AAD `projection:<projection_name>:<capture_id>:<entry_ref>`.
Revoking the capture deletes the entry, and destroys the key that sealed its
output (R11). An output can't be added for a capture that's revoked
([ADR 0007](../adr/0007-plugins.md)).

On revocation an implementation MUST, in one transaction:

1. delete every `projection_entry` for the revoked set, and
2. write one `projection_revocation` row per projection recording
   `entries_removed`.

**A projection with no `projection_revocation` row for a given revocation is
non-conformant**, even if its entries happen to be gone. The receipt is the
claim.

### `replay_watermark`, `replay_receipt` (R4)

A consumer re-derives state by reading `capture_event` in `sequence` order,
excluding `revoked_capture`. The derived state hashes to `state_hash`; two
replays over the same stream MUST produce the same hash.

### `grant_record`, `egress_record` (ADR 0001)

Serving-side only; see [ADR 0001](../adr/0001-serving-trust-boundary.md).

`expires_at` is NOT NULL: a grant with no expiry is not issuable.
`privacy_levels` carries a CHECK rejecting `sacred_mode`, so the level is
non-grantable **by construction** rather than by an application check someone
can forget.

`egress_record` is append-only and hash-chained over `prev_hash`.

- **`record_hash`** is the SHA-256, in hex, of this exact UTF-8 text:
  ```
  {"servedAt":…,"clientId":…,"grantId":…,"tool":…,"queryFingerprint":…,"captureIds":[…],"privacyLevelsServed":[…],"rowCount":N,"byteCount":N,"prevHash":…}
  ```
  - The keys come in that order, with no whitespace.
  - Strings are escaped as ECMAScript's `JSON.stringify` escapes them: `"`,
    `\`, and U+0000 to U+001F only, the control characters as `\b \t \n
    \f \r` or `\u00xx` in lower-case hex.
  - The first record's `prevHash` is 64 zeros.
- **`byte_count`** is the byte length of the served envelopes as a JSON array
  in that same form, with the envelope's keys in ADR 0001's order.
- **`query_fingerprint`** is the SHA-256 of `tool ‖ U+0000 ‖ query ‖ U+0000 ‖
  contains`. The query itself is never kept.

The store-layer suite recomputes the chain from the file, so a log written by
one implementation verifies in any other.

## Privacy levels (R5)

| Level | Meaning | Default servability |
|-------|---------|---------------------|
| `standard` | Ordinary captured content | Grantable |
| `sensitive` | Flagged private by the user or a rule | Not grantable by default |
| `excluded` | Captured but withheld from all derived use | Not grantable by default |
| `sacred_mode` | MUST never leave the device or reach any consumer | **Never grantable** |

## Storage contracts

- **Frames.** Text first; no pixels by default
  ([ADR 0005](../adr/0005-text-first-capture.md)). A screen capture is a
  `screen_text` event. An opt-in keyframe buffer may keep `screen_frame`
  payloads under a short retention of its own, sealed and erased like any
  other payload. Default budget: under 1 GB a month. Retention is R12.
- **Vector store.** The interface is defined in
  [`src/vector-store.js`](../../packages/schema/src/vector-store.js);
  **LanceDB** is the shipped default, chosen for being Rust-native over Apache
  Arrow and embeddable without a server process. A backend MAY be substituted,
  but R3 is mandatory regardless — run `conformance/vector-store.test.js`
  against an adapter to claim conformance.
- **Text extraction.** Accessibility-API text first, OCR as fallback. Cheaper
  than extracting from every frame, and higher fidelity where available.
- **Audio and transcription.** Transcription is in scope and runs on-device. A
  default ASR MUST be redistributable without a gate or a revenue limit — see
  the [daemon licensing table](../../packages/daemon/README.md). On macOS the
  default is the OS's own recogniser
  ([ADR 0004](../adr/0004-apple-on-device-models.md)). Diarization is
  opt-in, never a default dependency, because the available models are gated
  behind third-party account terms.

## Conformance

An implementation is conformant when it passes the **store layer** of
[`packages/schema/conformance`](../../packages/schema/conformance), driven
through the [driver protocol](DRIVER.md). That layer writes through your
implementation and then reads your store's files directly, so it holds any
language to the same bytes. The suite requires Node ≥ 22.13 and has **no
dependencies**:

```sh
PRESENCE_CAPTURE_DRIVER="/path/to/your-driver" npm run conformance:store
```

The reference implementation also passes an API layer covering its read path
(grants, envelope and egress, ADR 0001 T1–T12) and replay (R4). Together the
two layers cover 64 assertions, including the five that distinguish this
schema:

- **revocation propagation** — derived views and vector entries do not survive
  a revocation, and a receipt proves it;
- **derived-artifact revocation (R10)** — revoking audio removes its transcript,
  its alignment, and their embeddings;
- **replay determinism** — re-derivation from the event stream is reproducible,
  and revocation changes the result deterministically;
- **privacy enforcement** — `sacred_mode` is unreachable through any read path,
  and a grant naming it cannot be issued;
- **forensic erasure (R11)** — after a revocation, no file the store leaves
  holds the revoked content, its key or its sealed bytes, and the master key
  cannot recover it. Six mutant stores, each with one erasure step broken,
  must fail this check.

A schema that cannot fail these tests is not this schema.
