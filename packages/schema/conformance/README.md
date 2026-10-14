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
| `store/held-log.test.js` | R11: an erasure a reader holds up isn't reported done, and is finished durably, by any writer, once it can be |
| `store/writers.test.js` | With a second writer: R2 (a revocation's scope resolved under the write lock), R13 (older ranges included), R1 (`append_all`, all or nothing; two writers opening one store), R11 (the key refused with everything revoked), ADR 0001 (a grant revoked elsewhere, a malformed limit, a long search that leaves the write lock free) |
| `store/erasure.test.js` | R11: the forensic check |
| `store/mutation.test.js` | The forensic check itself: six broken stores must fail it |

`store/forensic.js` and `store/inspect.js` read a store as SCHEMA.md defines
it, with no help from the implementation that wrote it.

## Plugin kits

| File | What it checks |
|------|----------------|
| `plugins/sensor-kit.js` | A sensor plugin ([ADR 0007](../../../docs/adr/0007-plugins.md)): a valid header, observations that pass `cases/observations.json`, and captures that land as `sensor:<name>` through the gate. Run it with `bin/sensor-kit.js -- <command>` |
| `plugins/sensor-kit.test.js` | The kit itself: the git-activity example passes, three broken sensors fail, and the host drops observations while held and applies the user's exclusions |
| `plugins/projector-kit.js` | A projector plugin: loads it as the host would, runs it over a synthetic day through a grant made from its manifest, and revokes what it projected. Run it with `bin/projector-kit.js <module.wasm> <manifest.json>` |
| `plugins/projector-kit.test.js` | The host refusing modules that import anything, have unbounded memory or aren't the approved hash. The host containing modules that never return, keep state between captures, or return oversized, malformed or out-of-manifest output. `plugins/wasm.js` builds these modules, so no binaries are committed |

## Reference API layer

| File | Requirements | ADR 0001 tests |
|------|--------------|----------------|
| `api/append-only.test.js` | R1, R5, R6, R11 | — |
| `api/revocation.test.js` | R2, R3, R7, R10 | — |
| `api/replay.test.js` | R4 | — |
| `api/privacy.test.js` | R5 | T1–T5 |
| `api/egress.test.js` | — | T6–T12, and a reused reader whose grant was revoked |
| `api/vector-store.test.js` | R3 | — |
| `api/retention.test.js` | R12, and the retention schedule | — |
| `api/cases.test.js` | R8 exclusion and redaction, against the [shared cases](../cases/README.md) | — |
| `api/erasure.test.js` | R11: a writer stamps only the erasures its own truncation proved | — |
| `api/gate.test.js` | R1 and R13 through the gate: an observation lands whole or not at all, and one in a forgotten range is refused | — |

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
