# `@presence-capture/schema`

The specification, migration lineage, and conformance suite. **This is the
standard**; the other packages are implementations of it.

Spec: [`docs/spec/SCHEMA.md`](../../docs/spec/SCHEMA.md).

## Status

v0.1.0-draft. The spec is normative for v0.1 and may change until 1.0.0.

## Run the conformance suite

Requires Node ≥ 22.13. **No dependencies to install** — the suite runs on
`node:sqlite` and `node:test`.

```sh
cd packages/schema
npm test
```

Two layers ([conformance/README.md](conformance/README.md)):

| Layer | Proves |
|-------|--------|
| `conformance/store/` | Through the [driver protocol](../../docs/spec/DRIVER.md), for any implementation: append-only events, sealing in the agreed format, revocation that cascades (R10), prunes projections with receipts (R3) and **erases content from every byte on disk** (R11), and retention as revocation (R12) |
| `conformance/api/` | The reference read path: `sacred_mode` unreachable, grants enforced below the tool layer, every payload enveloped, egress hash-chained (ADR 0001 T1–T12), and deterministic replay (R4) |

## Contents

| Path | What |
|------|------|
| `migrations/` | Fresh lineage from `001`. Adopters inherit no upstream migration history |
| `src/store.js` | Reference implementation over SQLite |
| `src/driver.js`, `bin/driver.js` | The reference conformance driver |
| `src/vector-store.js` | Vector-store interface plus an in-memory reference backend |
| `src/types.d.ts` | TypeScript bindings |
| `bindings/python/` | Pydantic models mirroring the TS types |
| `conformance/` | The suite that defines conformance |

## Claiming conformance for your own implementation

Write a driver for your implementation ([DRIVER.md](../../docs/spec/DRIVER.md):
about ten operations over stdin and stdout), then run:

```sh
PRESENCE_CAPTURE_DRIVER="/path/to/your-driver" npm run conformance:store
```

For a substituted vector backend, swap `makeVectorStore` in
`conformance/api/vector-store.test.js` for your adapter factory. That file is
written to be retargeted.

If your implementation passes, open an issue. A second conformant
implementation is the contribution this project wants most.
