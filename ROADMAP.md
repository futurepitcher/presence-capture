# Roadmap

Phases are gated, not dated. The Mac-native version ships first, to 0.1.0.
Windows follows once it has. Both are held to the same conformance suite.

Done before this roadmap:
- the serving trust model ([ADR 0001](docs/adr/0001-serving-trust-boundary.md),
  accepted);
- schema spec v0.1, with migrations 001–004 and bindings;
- the local, read-only MCP server (`packages/mcp`).

## M0: Project foundation (in review)

- ✅ [Governance](GOVERNANCE.md): the Apache-2.0 pledge, funding, how decisions
  are made, and the path to maintainer.
- ✅ DCO sign-off, checked in CI. No contributor licence agreement.
- ✅ An [RFC process](rfcs/README.md) for the spec, the driver protocol and the
  MCP surface.
- ✅ A fake sensor that replays recorded fixtures through exclusion and
  redaction, so the store, search, MCP and evals can be worked on without a
  Mac.
- ✅ OpenSSF Scorecard, actions pinned to commits, Dependabot, CODEOWNERS,
  and issue and pull request templates.
- ☐ Repository settings: branch protection, Discussions, a roadmap board,
  GitHub Sponsors.

**Exit:** a contributor on Linux runs the suite and replays a fixture with no
Mac. Scorecard ≥ 7.

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

## M2: Native macOS daemon and plugin model (in progress)

The daemon is ported from PresenceVoice's working capture app.

- ✅ `CaptureStore` in Swift passes the store-layer suite through `pcap-driver`,
  forensic erasure included, and its stores open in the reference.
- ✅ Screen through ScreenCaptureKit and Vision OCR, with no pixels kept.
- ✅ Speech through SpeechAnalyzer for the mic and system audio, each of which
  can be turned off.
- ✅ An activity lane.
- ✅ Exclusion, redaction and sealing before disk, with the master key in the
  Keychain.
- ✅ Retention, and "Forget the last 15 minutes / hour" from the menu.
- ✅ CI on `macos-26`.
- ✅ Accessibility text ahead of OCR: the focused window only, what's
  visible, never a password field.
- ✅ Sensor plugins ([ADR 0007](docs/adr/0007-plugins.md)): out of process, in
  any language, through the same gate, with a conformance kit and a
  git-activity example. Hosted by the reference and the macOS app.
- ✅ Projector plugins ([ADR 0007](docs/adr/0007-plugins.md)): WebAssembly with
  no imports, a fresh instance per capture, pinned by hash, read through a
  grant. Outputs kept by the store under the capture's key, so revocation
  erases them. A kit of attacks the host must refuse or contain. Reference
  host only so far.
- ✅ Pinned sensors: run only as approved, from the menu, and not again once
  an executable or script changes.
- ☐ The projector host in the macOS app.
- ☐ A side-by-side parity trial against screenpipe, and a forensic check on
  a live store.

**Exit:**
- a clean Mac produces a store that passes the store-layer suite unmodified;
- "forget the last 15 minutes" passes the forensic check on a live store.

## M3: Recall, native MCP, public benchmarks

Built to [ADR 0008](docs/adr/0008-recall-indexes-in-memory.md): indexes live in
memory, and everything at rest is sealed.

- Keyword search and activity sessions, in memory. Vectors were measured and
  wait for a stronger model (ADR 0008, amended).
- A native `pcap-mcp` with `search`, `recent`, `timeline`, `now`, `session`
  and `transcript`.
- `pcap eval` for accuracy and latency.
- `pcap bench` for a reproducible comparison against other capture tools.

- ✅ The native read path, held to the store layer, with an egress log that's
  identical byte for byte across implementations.
- ✅ `pcap-mcp`: the native MCP server, which SQLite restricts to reads and
  egress records. It passes the same MCP conformance as the reference, now
  run against any server over stdio.
- ✅ Keychain trust for `pcap-mcp`, in-memory search, and `timeline`, `now`,
  `session` and `transcript`.
- ☐ Embeddings in the daemon, the macOS projector host, `pcap eval` and
  `pcap bench`.

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

- ✅ `pcap`, the command line: grants, what agents were given (`pcap egress`),
  forget, `pcap check`, and `pcap connect` for Claude Code, Claude Desktop and
  Cursor.
- ✅ The menu's set-up window, Connect an Agent…, Agents Read…, Keep Captures
  For and Check for Updates.

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
