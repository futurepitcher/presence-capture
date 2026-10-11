# Contributing

Thanks for looking. This project is pre-alpha, and the most useful
contributions right now aren't all code.

## What we want most

1. **A second implementation that passes the conformance suite.** The point of
   this project is a standard. An independent implementation proving the spec
   can be implemented is worth more than any feature. Write a driver
   ([DRIVER.md](docs/spec/DRIVER.md)) and run the store layer against it.
2. **Attacks on the trust model and on erasure.** Read
   [ADR 0001](docs/adr/0001-serving-trust-boundary.md) and
   [ADR 0002](docs/adr/0002-erasable-revocation.md), and tell us where they
   fail. Revoked content you can recover from disk is the most valuable bug
   you can report, privately ([SECURITY.md](SECURITY.md)).
3. **Spec review.** Requirements in [`SCHEMA.md`](docs/spec/SCHEMA.md) that are
   wrong, missing, or can't be implemented on your platform.
4. **A sensor plugin.** Something worth remembering that the built-in sensors
   don't capture. It's an executable that writes observations to stdout
   ([ADR 0007](docs/adr/0007-plugins.md)), checked by the sensor kit; see
   [`packages/plugins/git-activity`](packages/plugins/git-activity/README.md).
5. **Cases.** A redaction or exclusion case the shared files miss
   ([`packages/schema/cases/`](packages/schema/cases/README.md)).

Issues labelled `good first issue` are scoped to be done in an afternoon.

## Set up: any OS, no Mac needed

You need Node ≥ 22.13. There are no third-party dependencies.

```sh
git clone https://github.com/futurepitcher/presence-capture && cd presence-capture
npm install && npm test
```

To get a store with a realistic day in it, without capturing anything:

```sh
cd packages/schema
node bin/replay-fixture.js --store /tmp/day.sqlite --master-key-file /tmp/day.key fixtures/a-short-day.jsonl
```

The fake sensor replays recorded observations through the same steps the
daemon follows: exclude, then redact, then seal and write
([fixtures/README.md](packages/schema/fixtures/README.md)). Only the
daemon itself needs a Mac.

## A ten-minute tour

1. **The record** ([`SCHEMA.md`](docs/spec/SCHEMA.md),
   `packages/schema/migrations/`). An append-only log of *that* something was
   captured. *What* was captured is sealed per capture, in tables revocation
   erases.
2. **Revocation** (`packages/schema/src/store.js`, `revoke()`). This is the
   project's reason to exist. It cascades through `derived_from` (R10), prunes
   every projection with a receipt (R3), and destroys keys, text and bytes in
   the same transaction (R11).
3. **Conformance** (`packages/schema/conformance/`). The store layer drives
   any implementation through the driver protocol, then reads its files
   directly. `store/forensic.js` scans the disk for anything revoked. The API
   layer covers the reference read path.
4. **Serving** (`packages/mcp`, ADR 0001). Read-only and local-only. Grants
   are enforced in the store, every payload is wrapped as untrusted, and every
   read is logged in a hash chain.
5. **Capture** (`packages/daemon`, CONTRACT.md). It writes and never serves:
   exclude, dedupe, redact, seal, write.

## What to expect

- The schema is `0.x`. It will change without a migration path until `1.0.0`.
- **Conformance is defined by the suite, not the prose.** A spec change without
  a test is incomplete. Spec, driver protocol and MCP surface changes go
  through an [RFC](rfcs/README.md).
- **Changes to revocation, erasure or retention** need a test that fails before
  the change and passes after. A change to the forensic check needs a mutant
  it newly catches.
- We are deliberately not shipping MCP mutations or a public network listener.
  Pull requests adding either will be declined. That's a design position
  ([ADR 0001](docs/adr/0001-serving-trust-boundary.md)), not a backlog item.

## Before opening a pull request

- Open an issue first for anything beyond a typo or a doc fix.
- One concern per pull request.
- No new runtime dependency without a note saying why it's worth the
  supply-chain surface. This is a capture project, so dependency choices are
  security choices.
- **Sign off every commit** (`git commit -s`). See below.

## Sign-off and licence

Contributions are accepted under [Apache-2.0](LICENSE), with no contributor
licence agreement. Each commit carries a
[Developer Certificate of Origin](https://developercertificate.org/) sign-off,
certifying you have the right to submit it under that licence. CI checks it.

Forgot one? Run `git rebase --signoff main` and force-push your branch.

The core stays Apache-2.0 for good. See the pledge in
[GOVERNANCE.md](GOVERNANCE.md).
