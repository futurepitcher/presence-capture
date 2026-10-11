# Roadmap

Phases are gated, not dated. The Mac-native version ships first, to 0.1.0.
Windows follows once it has. Both are held to the same conformance suite.

Done before this roadmap:
- the serving trust model ([ADR 0001](docs/adr/0001-serving-trust-boundary.md),
  accepted);
- schema spec v0.1, with migrations 001–004 and bindings;
- the local, read-only MCP server (`packages/mcp`).

## M0: Project foundation

- Governance, with a public pledge that the core stays Apache-2.0.
- DCO sign-off.
- An RFC process for spec changes.
- A fake sensor that replays recorded fixtures, so the store, search, MCP and
  eval can be worked on without a Mac.
- OpenSSF Scorecard, signed tags, issue templates and Discussions.

**Exit:** a contributor on Linux runs the suite and the eval against the fake
sensor.

## M1: Make forgetting real ✅

- ✅ Revocation erases content ([ADR 0002](docs/adr/0002-erasable-revocation.md)).
  Content is sealed per capture, and keys, text and bytes go in the revoking
  transaction with an erasure receipt.
- ✅ A forensic check scans every file a store leaves (R11), and six mutant
  stores prove it fails stores that don't erase.
- ✅ Retention is a scheduled revocation ([ADR 0003](docs/adr/0003-retention-is-revocation.md)).
- ✅ Decisions on Apple on-device models ([ADR 0004](docs/adr/0004-apple-on-device-models.md))
  and text-first capture ([ADR 0005](docs/adr/0005-text-first-capture.md)).
- ✅ The suite split into a store layer, driven through the
  [driver protocol](docs/spec/DRIVER.md) any implementation can expose, and the
  reference API layer.
- ✅ Shared exclusion and redaction cases in `packages/schema/cases/`, with
  reference implementations. Near-duplicate cases wait for M2's dedupe
  decision.

**Exit:** a store written by another implementation can be checked by the
store-layer suite, forensic check included.

## M2: Native macOS daemon and plugin model

The daemon is ported from PresenceVoice's working capture app:
- ScreenCaptureKit, accessibility text, then Vision OCR;
- SpeechAnalyzer for the mic and system audio;
- an activity lane;
- redaction and sealing before disk, with the master key in the Keychain.

Sensor, Projector and Exporter plugin interfaces, each with a conformance kit,
in-process or out of process over the driver protocol.

**Exit:**
- a clean Mac produces a store that passes the store-layer suite unmodified;
- "forget the last 15 minutes" passes the forensic check on a live store.

## M3: Recall, native MCP, public benchmarks

- Projections for full-text search, vectors (`NLContextualEmbedding`) and
  activity sessions.
- A native `pcap-mcp` with `search`, `recent`, `timeline`, `now`, `session`
  and `transcript`.
- `pcap eval` for accuracy and latency.
- `pcap bench` for a reproducible comparison against other capture tools.

**Exit:** recall@5 ≥ 0.8, search p95 < 300 ms at 30 days of data, numbers
published.

## M3.5: Upgrade an existing agent

For people who already run their own assistant:
- an event feed;
- a local HTTP/JSON API with a Python client;
- on-device daily and session digests;
- `pcap connect <stack>` recipes;
- an Omi importer.

Remote access is opt-in, over a private network, behind its own ADR. Every
surface sits behind the same grants, envelope and egress log as MCP.

## M4: Mac 0.1.0

- A menu-bar app with pause, forget, exclusions, retention and an "agents
  read…" viewer.
- A signed, notarised, reproducible build with published hashes and an SBOM.
- An external privacy and security review.
- A docs site.

See [RELEASING.md](RELEASING.md).

**Exit:** a non-developer installs it and connects an agent in under five
minutes.

## Windows

A second native implementation once Mac 0.1.0 has shipped. It uses the
platform's own on-device APIs and passes the same store-layer suite, plugin
kits and eval.

## Not on the roadmap

- MCP mutations
- A public network listener
- Any hosted service
