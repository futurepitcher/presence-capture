# `presence-capture-mcp`

Local-only, read-only MCP server over a conformant capture store.

## Status

Pre-alpha, **blocked**. Phase P5 on the [roadmap](../../ROADMAP.md), gated on
[ADR 0001](../../docs/adr/0001-serving-trust-boundary.md) being accepted.

## Why it is gated

Serving a complete record of someone's screen to an agent that can act is an
indirect prompt-injection channel. Captured content is attacker-controlled: any
page the user looked at can plant instructions. The trust model is being written
before the surface ships.

## Planned design

- Local transport only. No network listener.
- Read-only. No mutations.
- Scopes enforced in the repository layer, below the tool handlers. Default deny.
- Every served row recorded in a user-queryable egress log.
- All payloads returned inside a declared untrusted envelope with provenance.
