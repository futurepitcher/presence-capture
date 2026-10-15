# `presence-capture-mcp`

Local-only, read-only MCP server over a conformant capture store.

## Status

Pre-alpha, implemented and under test. Phase P5 on the [roadmap](../../ROADMAP.md).

```sh
cd packages/mcp && npm test        # the reference, over stdio, no dependencies
PRESENCE_CAPTURE_MCP="/path/to/pcap-mcp" npm test    # any other MCP server, held to the same tests
```

The tests start the server under test as an MCP client would, over stdio,
with `--store <path> --grant <grant_id> --master-key-file <path>`. They
seed and inspect the store through the reference, which opens any conformant
store. The native server, `pcap-mcp` (in `packages/daemon`), passes the same
tests: all of them, the ADR 0001 §7 set below included.

Run it against a store:

```sh
npx presence-capture-mcp --store ~/.presence-capture/store.db --grant grn_... \
  --master-key-file ~/.presence-capture/master.key
```

It speaks newline-delimited JSON-RPC 2.0 on stdin/stdout and **opens no socket
of any kind**.

Content in the store is sealed (ADR 0002), so the server needs the store's
master key: 32 bytes, raw or as 64 hex characters, in a file only you can read.
On macOS the native app keeps it in the Keychain instead.

## Design

Everything that matters for safety lives in
[`@presence-capture/schema`](../schema), not here. Scopes are enforced in the
repository layer, the untrusted envelope is applied there, and egress is logged
there — so a bug in this package cannot over-serve. That is the point of
enforcing below the tool layer rather than inside it.

- **Local transport only.** No network listener.
- **Read-only.** Six tools, the same in `pcap-mcp`, the native server:

  | Tool | Answers |
  |------|---------|
  | `search(query, from?, to?, limit?)` | Keyword search (FTS5, BM25), best match first |
  | `recent(limit?)` | The newest captures first |
  | `timeline(from?, to?, limit?)` | Everything in a span (by default the last hour), in order |
  | `transcript(from?, to?, device?, limit?)` | What was said, from the microphone (`input`), this Mac (`output`), or both |
  | `now()` | The latest session, with its activity, screen text, and everything said in the last five minutes, newest first |
  | `session(id, limit?)` | One session and everything captured during it |

  A session ([`cases/sessions.json`](../schema/cases/sessions.json)) is a
  stretch of active time in one app and window, computed from activity, never
  stored. It carries ids and times only; what it was is in its envelopes.
  `resources/*`, `prompts/*` and `logging/*` are refused with "this server is
  tools-only", not merely unimplemented.
- **Recall in memory, never on disk**
  ([ADR 0008](../../docs/adr/0008-recall-indexes-in-memory.md)). The server
  reads what its grant admits into SQLite FTS5 in `:memory:`. That reading is
  recorded in the egress log as `index`, since it unsealed those rows. It's
  kept current on each call (new captures in, revoked ones out), and whatever
  it ranks is served by id through the grant again, so a revocation or a
  withdrawn grant takes effect at once.
- **Default deny.** No grant means an explicit authorization error, not an empty
  result a client would read as "nothing matched".
- **Grants resolve per call**, so revoking one takes effect mid-session.
- **No dependencies.** JSON-RPC is implemented directly rather than via an SDK:
  this package is a reference for a security boundary, and every dependency is
  supply-chain surface on the wrong side of it.

`initialize` returns instructions telling the client that content is
attacker-controlled and must be treated as data. A client that ignores them is
the residual risk ADR 0001 §6.2 describes.

## Why the gate exists

Serving a complete record of someone's screen to an agent that can act is an
indirect prompt-injection channel. Captured content is attacker-controlled: any
page the user looked at can plant text, and the capture pipeline records it
faithfully and attributes it correctly.
[ADR 0001](../../docs/adr/0001-serving-trust-boundary.md) names that chain (C1)
and sets the tests that hold the line.

## ADR 0001 §7 coverage

| Test | Proven in |
|------|-----------|
| T1 no-grant read | both suites |
| T2 `sacred_mode` unreachable | both suites |
| T3 scope filtering below tools | both suites |
| T4 default non-grantability | schema (`privacy.test.js`) |
| T5 grant expiry / revocation | both suites |
| T6 egress completeness | both suites |
| T7 log append-only | schema (`egress.test.js`) |
| T8 log not servable | both suites |
| T9 envelope coverage | both suites |
| T10 provenance integrity | schema (`egress.test.js`) |
| T11 read-only | both suites |
| T12 hash chain | both suites |

Plus one that is not a pass/fail guarantee but a documented behaviour: hostile
captured text **is** returned, labelled, with provenance it cannot forge. We do
not silently filter it, because a filter nobody can verify is a worse promise
than a label everybody can see.
