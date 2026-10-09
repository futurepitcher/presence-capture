# Roadmap

Phases are gated, not dated. **P1 blocks P5**: no MCP code ships before the
serving trust model is accepted.

## P0 — Repo foundation

Public repo, Apache-2.0, NOTICE, contributor docs, security policy, package
skeletons, CI.
**Exit:** repo public, CI green, no code of substance yet.

## P1 — Serving trust model ✅

[ADR 0001](docs/adr/0001-serving-trust-boundary.md) — **Accepted 2026-10-09.**
Threat model (5 adversaries, 5 named attack chains), grant model, hash-chained
egress log, untrusted-payload envelope, and a limits section stating what is
detected rather than prevented. Defines the T1–T12 conformance suite that gates
P5.

## P2 — Schema spec v0.1 ✅

Normative [`docs/spec/SCHEMA.md`](docs/spec/SCHEMA.md) with field-level
definitions and R1–R10. Migration lineage `001`–`004`. Reference implementation
over SQLite. Vector-store interface with LanceDB as the shipped default and an
in-memory reference backend. TypeScript and Pydantic bindings.

**32-assertion conformance suite, zero dependencies** (`node:sqlite` +
`node:test`), wired into CI. Covers revocation propagation with per-projection
receipts, transitive derived-artifact revocation, replay determinism,
`sacred_mode` unreachability, envelope coverage, provenance forgery resistance,
and egress hash-chain tamper detection.

## P3 — Classifier decoupling

Capture must not depend on any particular classification taxonomy. A
`CaptureClassifier` interface, with domain taxonomies living in adopters.
**Exit:** capture module builds and tests green with no taxonomy dependency.

## P4 — Reference daemon

macOS screen, audio, and activity capture writing schema v0.1, with on-device
transcription. Accessibility-API text first with Vision OCR fallback, redaction
before disk, frame dedupe, per-application and per-input-device exclusion.
Default ASR must be redistributable without a gate or revenue limit.
**Exit:** a clean machine runs the daemon and produces a conformant store,
including transcripts whose revocation propagates.

## P5 — Local MCP server ✅

[`packages/mcp`](packages/mcp): JSON-RPC 2.0 over stdio, no network listener,
no dependencies. Two read-only tools. Scopes, envelope and egress all enforced
in the store below the tool layer, so a bug in the protocol layer cannot
over-serve.

**Exit met:** 11 assertions covering ADR 0001 T1-T12 at the protocol surface,
plus an end-to-end stdio run returning an enveloped payload to a client
speaking raw JSON-RPC. An out-of-scope read fails closed with an explicit
authorization error and is logged.

## P6 — Public launch

Threat model published, 0.1.0 tagged, signed and notarised build on GitHub
Releases with published checksums and a documented from-source build.
**Exit:** a non-developer installs the notarised build and it captures; a
developer builds from source and gets the same behaviour.

## Not on the roadmap

- Remote or multi-client MCP transport (see P1's threat model)
- MCP mutations
- Windows or Linux daemons — the schema is platform-neutral; ports are welcome
- Any hosted service
