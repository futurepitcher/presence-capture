# `@presence-capture/schema`

The specification, migration lineage, and conformance suite. **This is the
standard**; the other packages are implementations of it.

Spec: [`docs/spec/SCHEMA.md`](../../docs/spec/SCHEMA.md).

## Status

v0.1.0-draft. The spec is normative for v0.1 and may change until 1.0.0.

## Run the conformance suite

Requires Node ≥ 22.5. **No dependencies to install** — the suite runs on
`node:sqlite` and `node:test`.

```sh
cd packages/schema
npm test
```

32 assertions across six files. The four that matter:

| File | Proves |
|------|--------|
| `conformance/revocation.test.js` | Revocation propagates to every projection with a receipt (R3), and cascades transitively through derived artifacts (R10) |
| `conformance/replay.test.js` | Re-derivation from the event stream is deterministic, and revocation changes it deterministically (R4) |
| `conformance/privacy.test.js` | `sacred_mode` is unreachable through any read path, and a grant naming it cannot be issued (R5, ADR 0001 T1–T5) |
| `conformance/egress.test.js` | Content never leaves unwrapped, provenance cannot be forged by content, and a tampered log breaks the chain (ADR 0001 T6–T12) |

Plus `append-only.test.js` (R1, R5, R6, R7) and `vector-store.test.js` (R3
against a substituted backend).

## Contents

| Path | What |
|------|------|
| `migrations/` | Fresh lineage from `001`. Adopters inherit no upstream migration history |
| `src/store.js` | Reference implementation over SQLite |
| `src/vector-store.js` | Vector-store interface plus an in-memory reference backend |
| `src/types.d.ts` | TypeScript bindings |
| `bindings/python/` | Pydantic models mirroring the TS types |
| `conformance/` | The suite that defines conformance |

## Claiming conformance for your own implementation

Point the suite at your store factory. For a substituted vector backend, swap
`makeVectorStore` in `conformance/vector-store.test.js` for your adapter
factory — that file is written to be retargeted.

If your implementation passes, open an issue. A second conformant
implementation is the contribution this project wants most.
