# Presence Capture

A menu-bar app for macOS that remembers the text on your screen, what you're
doing, and what's said, keeps it sealed on your Mac, and lets the agents you
choose read it, through a local, read-only MCP server and a grant you can take
back. Forget erases from disk, and a test reads the disk to check.

It's open source (Apache-2.0) and **not independently audited**: it's been
reviewed by Codex and Claude, and a conformance suite tests it.

## Start here

- [Quickstart](quickstart.md): install, set up, and ask an agent something.
- [Connecting an agent](connect.md): Claude Code, Claude Desktop, Cursor, and
  any other MCP client.
- [MCP tools](tools.md): what an agent can ask, and what it gets back.
- [FAQ](faq.md).

## How it works

- [How revocation works](revocation.md): what Forget guarantees, and how it's
  checked.
- [Threat model](threat-model.md): what's protected, from whom, and where that
  ends.
- [Known limits](known-limits.md).
- [Plugins](plugins.md): sensors and projectors.
- [Benchmarks](benchmarks.md): recall, speed, and the live checks.

## Releases

- [Verifying a release](verify.md): the attestation, the checksums and Apple's
  checks.
- [Building from source](building.md).

## Reference

- The store's [schema](spec/SCHEMA.md) and [driver contract](spec/DRIVER.md).
- Decision records: [serving](adr/0001-serving-trust-boundary.md),
  [erasable revocation](adr/0002-erasable-revocation.md),
  [retention](adr/0003-retention-is-revocation.md),
  [on-device models](adr/0004-apple-on-device-models.md),
  [text-first capture](adr/0005-text-first-capture.md),
  [plugins](adr/0007-plugins.md),
  [recall in memory](adr/0008-recall-indexes-in-memory.md).
- The code, issues and releases are on
  [GitHub](https://github.com/futurepitcher/presence-capture).
