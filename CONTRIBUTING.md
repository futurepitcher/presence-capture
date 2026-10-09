# Contributing

This project is pre-alpha. The most useful contributions right now are not code.

## What we want most

1. **A second implementation that passes the conformance suite.** The point of
   this project is a standard. A competing implementation proving the spec is
   implementable is worth more than any feature.
2. **Attacks on the trust model.** Read
   [ADR 0001](docs/adr/0001-serving-trust-boundary.md) and tell us where it fails.
   Especially the indirect-prompt-injection analysis.
3. **Spec review.** [`docs/spec/SCHEMA.md`](docs/spec/SCHEMA.md) is a draft.
   Requirements that are wrong, missing, or unimplementable on your platform are
   the highest-value issues you can file.

## What to expect

- The schema is `0.x`. It will change without a migration path until `1.0.0`.
- Conformance is defined by the suite, not the prose. A spec change without a
  corresponding test is incomplete.
- Changes to revocation semantics (requirement R2/R3) need a test that fails
  before the change and passes after. That property is the reason this project
  exists.
- We are deliberately not shipping a remote MCP transport or MCP mutations. PRs
  adding either will be declined until the threat model in ADR 0001 is resolved
  and published. This is a design position, not a backlog item.

## Before opening a PR

- Open an issue first for anything beyond a typo or a doc fix.
- One concern per PR.
- No new runtime dependency without a note in the PR saying why it is worth the
  supply-chain surface. This is a capture project; dependency choices are
  security choices.

## Licence

Contributions are accepted under [Apache-2.0](LICENSE). By opening a PR you
confirm you have the right to submit the work under that licence.
