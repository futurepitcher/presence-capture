# `presence-capture-mcp`

Local-only, read-only MCP server over a conformant capture store.

## Status

Pre-alpha, not yet implemented. Phase P5 on the [roadmap](../../ROADMAP.md).

The trust model is settled: [ADR 0001](../../docs/adr/0001-serving-trust-boundary.md)
is **Accepted**. The remaining gate is its §7 conformance suite — twelve tests
(T1–T12) that must exist and pass before anything here is releasable.

## Why the gate exists

Serving a complete record of someone's screen to an agent that can act is an
indirect prompt-injection channel. Captured content is attacker-controlled: any
page the user looked at can plant text, and the capture pipeline will record it
faithfully and attribute it correctly. ADR 0001 names that chain (C1), says what
the envelope does and does not fix, and sets the tests that hold the line.

## Planned design

- Local transport only. No network listener.
- Read-only. No mutations.
- Scopes enforced in the repository layer, below the tool handlers. Default deny;
  `sacred_mode` not grantable by construction.
- Every served row recorded in a hash-chained, append-only egress log that is
  itself not servable.
- All payloads returned inside the declared untrusted envelope, with provenance
  populated at capture time rather than derived from content.
