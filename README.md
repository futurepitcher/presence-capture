# Presence Capture

**Memory for your agents that you can take back.** A menu-bar app for macOS
that remembers the text on your screen, what you're doing, and what's said,
keeps it sealed on your Mac, and lets the agents you choose read it, through a
local, read-only MCP server and a grant you can withdraw. Forget erases from
disk, and a test reads the disk to check.

> **0.1: the first release.** It's **not independently audited**. Codex and
> Claude have reviewed it, and a conformance suite tests it. The schema is at
> v0.x and can change. See [ROADMAP.md](ROADMAP.md) and the
> [threat model](docs/threat-model.md).

## Install

A Mac with Apple silicon and macOS 14 or later. Hearing and dictation need
macOS 26.

- **DMG:** from [Releases](https://github.com/futurepitcher/presence-capture/releases).
  It's signed, notarized and attested: [check it](docs/verify.md) before you
  open it.
- **Homebrew:** `brew install --cask futurepitcher/tap/presence-capture`.
- **From source**, or on an Intel Mac: [docs/building.md](docs/building.md).

Then follow the [quickstart](docs/quickstart.md): the set-up window asks for
each permission as you get to it, and connects Claude Code, Claude Desktop or
Cursor in one step ([connecting an agent](docs/connect.md)).

## What it does

- **Captures text, not pixels.** Every 5 seconds: the text of the windows in
  front (Accessibility, then on-device OCR), the app and window you're in, and,
  on macOS 26, transcripts of what the Mac plays and, if you turn it on, what
  the microphone hears. No screenshots or audio are kept.
- **Skips what you exclude, and redacts.** Apps and windows on your exclusion
  list, password fields and the system's own screens are never read. Keys,
  tokens, emails, card numbers and the like are redacted before anything is
  written.
- **Seals everything at rest.** Each capture under its own key; the master key
  in your Keychain.
- **Serves agents through grants.** `pcap-mcp` has six read-only tools:
  `search`, `recent`, `timeline`, `transcript`, `now` and `session`
  ([reference](docs/tools.md)). A grant limits what an agent may read and for
  how long. Every row served is in a hash-chained log you can see in **Agents
  Read…**, and every row is labeled as untrusted content, not instructions.
- **Forgets for real.** Forget the last 15 minutes or hour, or let retention
  age captures out (14 days by default): the content and its key are erased in
  one transaction, the write-ahead log is truncated, and a receipt says so.
  [How revocation works](docs/revocation.md).
- **Dictation (experimental, macOS 26).** Hold a key, speak, and the words are
  typed where the cursor is, transcribed on this Mac. Never into a password
  field. Off until you turn it on ([limits](docs/known-limits.md#dictation)).

What you captured leaves your Mac only when an agent you connected reads it.
There's no account, no telemetry and no server. Speech and text recognition run
on the device ([ADR 0004](docs/adr/0004-apple-on-device-models.md)). The only
other requests are Check for Updates…, when you choose it, and macOS fetching
its speech model once. Questions: [FAQ](docs/faq.md).

## Why this exists

Continuous personal capture has no credible open substrate. Screenpipe
relicensed away from MIT in June 2026. Rewind was acquired and shut down. What
remains is either copyleft in a way that blocks embedding, unmaintained, or a
screenshot loop with an ad-hoc schema. No two projects in this category can read
each other's data.

Capturing the screen is the easy part. The hard part, the part everyone
skipped, is making the record **revocable in a way you can prove**:

- **Revocation is an event, not a delete.** It follows `derived_from` into
  everything derived, so revoking audio revokes its transcript too, and every
  projection gets a receipt.
- **Revocation erases.** It destroys the key, the text and the bytes in the
  same transaction. A forensic test scans every file the store leaves for what
  was revoked, and six broken stores prove the test can fail.
- **Retention is a scheduled revocation**, with the same receipts, so nothing
  leaves the store without a record of why.
- **Privacy levels are enforced at the read boundary**, in the store layer,
  below any tool.
- **Late writes are refused.** Speech transcribed after you forgot the moment
  it was said is never stored.

This repository publishes that as a specification with a conformance suite, a
reference implementation that proves the spec works, and the macOS app that
ships it.

## Packages

| Package | What it is |
|---------|-----------|
| [`packages/schema`](packages/schema) | The specification, migrations and conformance suite: **the standard**. Zero dependencies. The store layer checks any implementation through a [driver](docs/spec/DRIVER.md) |
| [`packages/daemon`](packages/daemon) | The macOS app, with `pcap-mcp` (the MCP server) and `pcap` (the command line) inside it. Its store passes the same suite |
| [`packages/mcp`](packages/mcp) | The reference MCP server. It and `pcap-mcp` pass the same MCP conformance |

**Try the spec without a Mac:** `npm install && npm test` (Node 22.13 or later,
no third-party dependencies). `packages/schema/bin/replay-fixture.js` fills a
store with a synthetic day.

## Design positions

**Local-only, read-only, for now.** No network listener and no MCP mutations.
Serving a record of someone's screen to an agent that can act is an indirect
prompt-injection channel with the whole screen as the payload: any page you
look at can plant instructions. The [threat model](docs/threat-model.md) and
[ADR 0001](docs/adr/0001-serving-trust-boundary.md) say what that means.

**Conformance over contributions.** The contribution we most want is a second
implementation that passes the suite, not a PR to our app.

**No hosted anything.** No account, no telemetry, no server. Nothing in the
default install is gated behind a third-party account or limited by your
revenue. A fresh clone runs.

## Documentation

All of it is in [`docs/`](docs/index.md): the quickstart, connecting agents,
the tool reference, how revocation works, the threat model, known limits,
plugins, benchmarks, verifying a release, and the specification and decision
records.

## Relationship to PresenceOS

Extracted from [PresenceOS](https://github.com/futurepitcher/PresenceOS), which
is its first adopter and runs the conformance suite against itself. PresenceOS's
behavioural runtime and retrieval engine are not part of this project.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for a ten-minute tour and setup on any
OS. Spec changes go through [RFCs](rfcs/README.md), and decisions are
described in [GOVERNANCE.md](GOVERNANCE.md). Report vulnerabilities privately:
[SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE), chosen over MIT for the explicit patent grant.

**The core stays Apache-2.0.** No relicensing, no contributor licence
agreement, and nothing paid ever gates capture, memory or erasure. See the
pledge in [GOVERNANCE.md](GOVERNANCE.md).
