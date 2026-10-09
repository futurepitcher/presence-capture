# `presence-capture-mcp`

Local-only, read-only MCP server over a conformant capture store.

## Status

Pre-alpha, implemented and under test. Phase P5 on the [roadmap](../../ROADMAP.md).

```sh
cd packages/mcp && npm test        # 11 assertions, no dependencies
```

Run it against a store:

```sh
npx presence-capture-mcp --store ~/.presence-capture/store.db --grant grn_...
```

It speaks newline-delimited JSON-RPC 2.0 on stdin/stdout and **opens no socket
of any kind**.

## Design

Everything that matters for safety lives in
[`@presence-capture/schema`](../schema), not here. Scopes are enforced in the
repository layer, the untrusted envelope is applied there, and egress is logged
there — so a bug in this package cannot over-serve. That is the point of
enforcing below the tool layer rather than inside it.

- **Local transport only.** No network listener.
- **Read-only.** Two tools, `search` and `recent`. `resources/*`, `prompts/*`
  and `logging/*` are refused with "this server is tools-only", not merely
  unimplemented.
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
