# Conformance suite

This suite, not the prose in `docs/spec/SCHEMA.md`, defines conformance. Where
they disagree, the suite is right.

```sh
cd packages/schema && npm test
```

Node ≥ 22.5, no dependencies.

## Mapping

| Test file | Requirements | ADR 0001 tests |
|-----------|--------------|----------------|
| `append-only.test.js` | R1, R5, R6, R11 | — |
| `revocation.test.js` | R2, R3, R7, R10 | — |
| `replay.test.js` | R4 | — |
| `privacy.test.js` | R5 | T1–T5 |
| `egress.test.js` | — | T6–T12 |
| `vector-store.test.js` | R3 | — |
| `forensic.test.js` | R11 | — |
| `mutation.test.js` | R11 (the check itself) | — |
| `retention.test.js` | R12 | — |

## The ones that matter

If `revocation.test.js`, `forensic.test.js`, `privacy.test.js` T2, or
`egress.test.js` T9 are weakened, the project has lost its reason to exist.
They assert, in order: revoked data does not survive in derived views; revoked
content does not survive on disk; `sacred_mode` is unreachable; and captured
content never crosses a boundary unlabelled.

`forensic.js` exports `forensicErasureCheck(openStore)`, which returns a list
of failures for any store that follows the table layout in SCHEMA.md. Run it
against your implementation's store; `mutation.test.js` shows it failing six
broken ones.
