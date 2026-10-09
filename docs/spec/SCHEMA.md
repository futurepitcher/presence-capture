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

| # | Requirement | Conformance test |
|---|-------------|------------------|
| R1 | Capture events are append-only; payloads are content-addressed and stored apart from metadata | `append-only.test.js` |
| R2 | Revocation is a first-class event, never a row delete | `revocation.test.js` |
| R3 | Revocation propagates to projections and vector indices, verifiably | `revocation.test.js`, `vector-store.test.js` |
| R4 | Replay receipts and watermarks record consumer position; replay is deterministic | `replay.test.js` |
| R5 | Every event carries a privacy level, enforced at read boundaries | `privacy.test.js` |
| R6 | Classification taxonomy is pluggable | `append-only.test.js` |
| R7 | Near-identical frames are deduplicated before persistence | `revocation.test.js` |
| R8 | Per-application exclusion is supported at capture time | daemon-side; not schema-testable |
| R9 | The event shape is platform-neutral | by inspection |
| R10 | Derived artifacts — transcripts, alignments, embeddings — are projections subject to R3 | `revocation.test.js` |

## Entities

### `capture_payload` (R1)

Bulk bytes, addressed by content so identical captures store once.

| Field | Type | Notes |
|-------|------|-------|
| `payload_hash` | TEXT PK | SHA-256 hex over the bytes |
| `byte_count` | INTEGER | |
| `media_type` | TEXT | e.g. `image/heic`, `audio/wav` |
| `storage_uri` | TEXT | Where the bytes live. Implementations MAY use segment-plus-offset form |
| `created_at` | TEXT | ISO 8601 |

### `capture_event` (R1, R5, R6, R7, R9, R10)

| Field | Type | Notes |
|-------|------|-------|
| `capture_id` | TEXT PK | |
| `sequence` | INTEGER UNIQUE | Monotonic. The replay ordering — **not** `captured_at`, which can go backwards |
| `captured_at` | TEXT | ISO 8601 |
| `capture_type` | TEXT | `screen_frame`, `screen_text`, `audio_segment`, `audio_transcript`, `audio_alignment`, `activity` |
| `source` | TEXT | Source family. Platform-neutral (R9) |
| `source_app` | TEXT NULL | Bundle id or executable where known |
| `source_url` | TEXT NULL | MUST be `NULL` when not establishable. MUST NOT be inferred from content |
| `privacy_level` | TEXT | `standard`, `sensitive`, `excluded`, `sacred_mode` |
| `classification` | TEXT NULL | Opaque to the schema (R6) |
| `payload_hash` | TEXT NULL | FK to `capture_payload` |
| `content_text` | TEXT NULL | Extracted text. **Attacker-controlled** |
| `extraction` | TEXT NULL | `accessibility`, `ocr`, `asr`, `none` |
| `derived_from` | TEXT NULL | FK to `capture_event`. Set on derived artifacts (R10) |
| `dedupe_key` | TEXT NULL | Unique where not null (R7) |

Implementations MUST reject UPDATE and DELETE against this table. The reference
implementation enforces this with database triggers rather than application
convention, because a convention is not a guarantee.

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

## Privacy levels (R5)

| Level | Meaning | Default servability |
|-------|---------|---------------------|
| `standard` | Ordinary captured content | Grantable |
| `sensitive` | Flagged private by the user or a rule | Not grantable by default |
| `excluded` | Captured but withheld from all derived use | Not grantable by default |
| `sacred_mode` | MUST never leave the device or reach any consumer | **Never grantable** |

## Storage contracts

- **Frames.** Encoded video segments plus a frame index, not loose images.
  Planning figure from a comparable implementation: **50–70 GB/month** at a
  2-second interval. Implementations MUST state a retention and compaction
  contract.
- **Vector store.** The interface is defined in
  [`src/vector-store.js`](../../packages/schema/src/vector-store.js);
  **LanceDB** is the shipped default. A backend MAY be substituted, but R3 is
  mandatory regardless. Run `conformance/vector-store.test.js` against an
  adapter to claim conformance.
- **Text extraction.** Accessibility-API text first, OCR as fallback. Cheaper
  than extracting from every frame, and higher fidelity where available.
- **Audio and transcription.** Transcription is in scope and runs on-device. A
  default ASR MUST be redistributable without a gate or a revenue limit — see
  the [daemon licensing table](../../packages/daemon/README.md). Diarization is
  opt-in, never a default dependency, because the available models are gated
  behind third-party account terms.

## Conformance

An implementation is conformant when it passes
[`packages/schema/conformance`](../../packages/schema/conformance). The suite
requires Node ≥ 22.5 and has **no dependencies** — clone and run `npm test`.

It currently covers 32 assertions, including the four that distinguish this
schema:

- **revocation propagation** — derived views and vector entries do not survive
  a revocation, and a receipt proves it;
- **derived-artifact revocation (R10)** — revoking audio removes its transcript,
  its alignment, and their embeddings;
- **replay determinism** — re-derivation from the event stream is reproducible,
  and revocation changes the result deterministically;
- **privacy enforcement** — `sacred_mode` is unreachable through any read path,
  and a grant naming it cannot be issued.

A schema that cannot fail these tests is not this schema.
