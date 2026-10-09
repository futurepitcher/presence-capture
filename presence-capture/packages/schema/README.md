# `@presence-capture/schema`

The specification, migration lineage, and conformance suite. **This is the
standard**; the other packages are implementations of it.

See [`docs/spec/SCHEMA.md`](../../docs/spec/SCHEMA.md).

## Status

Pre-alpha. Spec drafting is phase P2 on the [roadmap](../../ROADMAP.md).

## Planned contents

- `migrations/` — fresh lineage starting at `001`. Adopters do not inherit any
  upstream migration history.
- `conformance/` — the executable suite that defines conformance. Must include
  revocation-propagation, replay-determinism, and privacy-enforcement tests.
- `bindings/` — TypeScript types and Python models generated from one source.
