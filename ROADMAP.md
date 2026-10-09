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

## P2 — Schema spec v0.1

Normative `docs/spec/SCHEMA.md`, migration lineage from 001, conformance suite
including revocation-propagation, replay-determinism, and derived-artifact
revocation tests, plus generated type bindings. Settles the frame-storage
contract. Vector-store interface with **LanceDB** as the shipped default.
**Exit:** the reference adopter passes the conformance suite.

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

## P5 — Local MCP server

Read-only, local transport only, scopes enforced below the tool layer, egress
log, untrusted envelope.
**Exit:** a third-party MCP client reads a scoped view; an out-of-scope read
fails closed and is logged.

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
