# Conformance suite

This suite, not the prose in `docs/spec/SCHEMA.md`, defines conformance. Where
they disagree, the suite is right.

```sh
cd packages/schema && npm test
```

Node ≥ 22.13, no dependencies.

## Two layers

| Layer | Directory | Reaches the implementation through | Who runs it |
|-------|-----------|-----------------------------------|-------------|
| **Store** | `store/` | The [driver protocol](../../../docs/spec/DRIVER.md), then the store's files read directly | **Every implementation.** This is what conformance means |
| **Reference API** | `api/` | The JavaScript API of `src/store.js` | The reference implementation, and anyone reusing its read path |

Check your own implementation with the store layer:

```sh
PRESENCE_CAPTURE_DRIVER="/path/to/your-driver" npm run conformance:store
```

Unset, it drives the reference driver process (`bin/driver.js`), the same way.

## Store layer

| File | Requirements |
|------|--------------|
| `store/capture.test.js` | R1, R5, R6, R7, R11 (sealing format, key refusal) |
| `store/revocation.test.js` | R2, R3, R10, R11 (erasure receipts) |
| `store/retention.test.js` | R12 |
| `store/erasure.test.js` | R11: the forensic check |
| `store/mutation.test.js` | The forensic check itself: six broken stores must fail it |

`store/forensic.js` and `store/inspect.js` read a store as SCHEMA.md defines
it, with no help from the implementation that wrote it.

## Reference API layer

| File | Requirements | ADR 0001 tests |
|------|--------------|----------------|
| `api/append-only.test.js` | R1, R5, R6, R11 | — |
| `api/revocation.test.js` | R2, R3, R7, R10 | — |
| `api/replay.test.js` | R4 | — |
| `api/privacy.test.js` | R5 | T1–T5 |
| `api/egress.test.js` | — | T6–T12 |
| `api/vector-store.test.js` | R3 | — |
| `api/retention.test.js` | R12, and the retention schedule | — |
| `api/cases.test.js` | R8 exclusion and redaction, against the [shared cases](../cases/README.md) | — |

ADR 0001's T1–T12 are checked again at the MCP protocol surface in
`packages/mcp/conformance`.

## The ones that matter

If `store/revocation.test.js`, `store/erasure.test.js`, `api/privacy.test.js`
T2, or `api/egress.test.js` T9 are weakened, the project has lost its reason to
exist. They assert, in order:
- revoked data does not survive in derived views;
- revoked content does not survive on disk;
- `sacred_mode` is unreachable;
- captured content never crosses a boundary unlabelled.
