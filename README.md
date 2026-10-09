# Presence Capture

**An open capture substrate.** Screen, activity, and transcribed ambient audio
into a revocable, replayable, privacy-classified event store — queryable by any
model or tool over MCP, with the user able to see and revoke exactly what was
served.

> **Status: pre-alpha.** The schema is at v0.x and will change. Nothing here is
> ready to depend on yet. See [ROADMAP.md](ROADMAP.md).

## Why this exists

Continuous personal capture has no credible open substrate. Screenpipe
relicensed away from MIT in June 2026. Rewind was acquired and shut down. What
remains is either copyleft in a way that blocks embedding, unmaintained, or a
screenshot loop with an ad-hoc schema. No two projects in this category can read
each other's data.

Capturing the screen is the easy part. The hard part — the part everyone skipped —
is making the resulting record **revocable in a way you can prove**:

- Capture events are append-only, with content-addressed payloads.
- **Revocation is an event, not a delete**, and it propagates into derived
  projections and vector indices. A delete cannot prove the derived data went too.
- **Replay receipts and watermarks** let a consumer prove which events it
  processed and re-derive deterministically.
- Every event carries a **privacy level that is enforced at read boundaries**,
  not advisory metadata attached to it.
- **Derived artifacts are projections.** A transcript is derived from an audio
  payload, so revoking the audio revokes the transcript, its alignment, and its
  embeddings. The conformance suite tests exactly that.

That's the contribution. This repo publishes it as a specification with a
conformance suite, plus a reference implementation that proves the spec works.

## Packages

| Package | What it is |
|---------|-----------|
| [`packages/schema`](packages/schema) | The specification, migrations, and conformance suite. **The actual standard.** v0.1.0-draft, 32 passing assertions, zero dependencies |
| [`packages/daemon`](packages/daemon) | macOS reference implementation — ScreenCaptureKit, AVAudioEngine, activity capture |
| [`packages/mcp`](packages/mcp) | Local-only MCP server with read scopes and an egress log. Implemented; 11 passing assertions |

## Design positions

**Try it:** `npm install && npm test` — Node ≥ 22.5, no third-party
dependencies. 43 assertions across the schema and MCP suites. They define
conformance, so they are also the fastest way to see what this project claims.

**Local-only, read-only, for now.** v1 ships no network listener and no MCP
mutations. Not because it is hard to add, but because serving a complete record
of someone's screen to an agent that can act is an indirect prompt-injection
channel with the whole screen as the payload surface. Captured content is
attacker-controlled: any page you look at can plant instructions. We are writing
that threat model down before we ship the surface. See
[docs/adr/0001-serving-trust-boundary.md](docs/adr/0001-serving-trust-boundary.md).

**Conformance over contributions.** The contribution we most want is a second
implementation that passes the suite — not a PR to our daemon.

**No hosted anything.** No account, no telemetry, no server. That extends to
model dependencies: nothing in the default install is gated behind a third-party
account or limited by your revenue. A fresh clone runs.

## Relationship to PresenceOS

Extracted from [PresenceOS](https://github.com/futurepitcher/PresenceOS), which
is its first adopter and runs the conformance suite against itself. PresenceOS's
behavioural runtime and retrieval engine are not part of this project.

## License

[Apache-2.0](LICENSE). Chosen over MIT for the explicit patent grant.
