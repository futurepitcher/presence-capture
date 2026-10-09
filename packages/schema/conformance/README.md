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
| `append-only.test.js` | R1, R5, R6 | — |
| `revocation.test.js` | R2, R3, R7, R10 | — |
| `replay.test.js` | R4 | — |
| `privacy.test.js` | R5 | T1–T5 |
| `egress.test.js` | — | T6–T12 |
| `vector-store.test.js` | R3 | — |

## The ones that matter

If `revocation.test.js`, `privacy.test.js` T2, or `egress.test.js` T9 are
weakened, the project has lost its reason to exist. They assert, in order:
revoked data does not survive in derived views; `sacred_mode` is unreachable;
and captured content never crosses a boundary unlabelled.
