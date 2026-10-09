# Capture Schema Specification

**Version:** 0.1.0-draft
**Status:** Draft. Not yet normative. Shape will change.

## Stability statement

While this document is at `0.x`, any part may change without a migration path.
A `1.0.0` release will commit to backward compatibility for the event shape and
the revocation semantics; everything else remains advisory.

Conformance is defined by the suite in `packages/schema/conformance`, not by this
prose. Where the two disagree, the suite is correct and this document is a bug.

## Scope

This specification defines how continuous capture of screen, activity, and
ambient audio is recorded such that:

1. the record is append-only and auditable,
2. any part of it can be revoked in a way that provably propagates to derived
   data, and
3. reads can be constrained by a privacy classification that the storage layer
   enforces.

It does **not** define how capture is performed, what OCR or ASR engine is used,
how content is classified, or what a consumer does with the result.

## Design requirements

| # | Requirement | Rationale |
|---|-------------|-----------|
| R1 | Capture events are append-only; payloads are content-addressed and stored separately from metadata | Enables audit and replay; keeps bulk out of the index |
| R2 | Revocation is a first-class event, never a row delete | A delete cannot demonstrate that derived data was also removed |
| R3 | Revocation propagates to projections and vector indices, verifiably | **The distinguishing property of this schema** |
| R4 | Replay receipts and watermarks record what a consumer has processed | Deterministic re-derivation; crash recovery |
| R5 | Every event carries a privacy level, enforced at read boundaries | Turns classification into a guarantee |
| R6 | Classification taxonomy is pluggable | A domain model is an application's opinion, not a capture primitive |
| R7 | Near-identical frames are deduplicated before persistence | Cuts storage and downstream extraction cost together |
| R8 | Per-application exclusion is supported at capture time | Consent must be expressible before data exists |
| R9 | The event shape is platform-neutral | A Windows or Linux implementation should be conformant, not a fork |
| R10 | Derived artifacts — transcripts, alignments, embeddings — are projections, subject to R3 | Revoking an audio capture must revoke what was derived from it |

## Core entities

> Draft. Field-level definitions land in P2.

- **Capture** — an append-only event: when, what source, what type, what privacy
  level, what classification, pointer to payload.
- **Payload** — content-addressed blob. Frames, audio segments, extracted text.
- **Revocation** — an event rendering one or more captures unreadable, carrying
  scope and reason.
- **Projection revocation** — the record that a revocation has been applied to a
  named derived view or index.
- **Replay receipt / watermark** — a consumer's position and integrity proof over
  the event stream.
- **Transcript** — a projection over an audio payload, not a capture in its own
  right. Alignment and diarization are further projections over a transcript.
  All inherit R3: revoking the audio revokes the chain.
- **Grant** — a scoped read permission issued to a named client.
- **Egress record** — what was served, to whom, under which grant.

## Privacy levels

| Level | Meaning | Default servability |
|-------|---------|---------------------|
| `standard` | Ordinary captured content | Grantable |
| `sensitive` | Content the user or a rule flagged as private | Not grantable by default |
| `excluded` | Captured but withheld from all derived use | Not grantable by default |
| `sacred_mode` | Must never leave the device or reach any consumer | **Never grantable** |

## Storage contracts

Open for P2, recorded here so the decisions are not made implicitly:

- **Frames.** Encoded video segments plus a frame index, not loose images.
  Planning figure from a comparable implementation: **50–70 GB/month** at a
  2-second interval. The spec must state a retention and compaction contract.
- **Vector store.** The spec defines an interface; **LanceDB** is the shipped
  default. An implementation may substitute a backend, but revocation
  propagation (R3) is mandatory regardless of backend. That is the one thing the
  interface does not make optional.
- **Text extraction.** Accessibility-API text first, OCR as fallback. Cheaper
  than extracting from every frame and higher fidelity where available.
- **Audio and transcription.** Transcription is in scope and runs on-device. The
  default ASR must be redistributable without a gate or a revenue limit — see
  the daemon's licensing table. Diarization is opt-in, never a default
  dependency, because the available models are gated behind third-party account
  terms.

## Conformance

An implementation is conformant when it passes `packages/schema/conformance`.
That suite must include, at minimum:

- a revocation-propagation test that fails if derived views or vector entries
  survive a revocation;
- a replay-determinism test that fails if re-derivation from the event stream
  produces a different projection;
- a privacy-enforcement test that fails if `sacred_mode` content is reachable
  through any read path;
- a **derived-artifact revocation test**: revoke an audio capture, assert its
  transcript, alignment, and vector entries are gone (R10).

A schema that cannot fail these tests is not this schema.
