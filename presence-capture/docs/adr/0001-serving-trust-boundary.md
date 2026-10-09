# ADR 0001: Serving capture over MCP inverts the trust boundary

## Status

Proposed — **blocks `packages/mcp`**

## Context

The established posture for MCP in this lineage is that MCP is an adapter
boundary, not a trust model: tool output is untrusted input, new servers begin
quarantined and read-only, credentials are scoped to the adapter and never
exposed to workers.

That posture governs a client **consuming** servers. Serving a capture store
inverts every arrow:

- The untrusted party is now the **client**, not the server.
- The asset at risk is a complete record of a person's screen and audio.
- The content being served was **authored by third parties** — every web page,
  message, and document the user looked at.

None of the existing guidance covers this direction, and the projects in this
category have not addressed it at all.

## Decision

### 1. Read scopes are enforced below the tool layer

A privacy level on a capture event is a guarantee, not a tag. Scope filtering
happens in the repository layer, beneath any tool handler, so no tool
implementation and no client argument can bypass it.

Grants are per-client and enumerate: domain, time range, privacy level, capture
type, and source.

- A client with no grant receives **nothing**. Default deny.
- `sensitive` and `excluded` are not grantable by default.
- `sacred_mode` is **not grantable at all**, by construction, with a test that
  fails if it ever becomes servable.

### 2. Egress is accounted for

Every served row is attributable to a client identity and the grant that
permitted it, in a durable log the user can query. Revoking a grant leaves the
historical record visible — the user needs to know what was already read.

The egress log is not itself servable over MCP.

Without this, "local-first" is a claim rather than a property.

### 3. Served payloads are marked untrusted at the protocol level

Captured content is attacker-controlled. Serving it to an agent that can act
makes the capture store a general-purpose injection channel into every tool the
user has connected — with the user's entire screen as the available payload
surface.

Therefore:

- Payloads are returned inside a declared untrusted envelope. They are never
  interpolated into a response as bare text.
- Payloads carry provenance: source application, URL where known, capture time.
- v1 binds to a local transport only. There is no network listener.
- The threat model is published with its limits stated plainly, including what
  the envelope does **not** solve: a sufficiently credulous client will still act
  on enveloped content, and we cannot prevent that from the server side.

### 4. No mutations in v1

Read-only. A client cannot write canonical capture state, and no capture event
originates from a tool call.

## Consequences

- `packages/mcp` cannot ship until the scope enforcement, egress log, and
  envelope exist and are tested. This is a hard sequencing constraint.
- Remote and multi-client transports are deferred, deliberately and publicly.
- Clients must handle the envelope to get useful content, which raises
  integration cost. Accepted: the alternative is shipping an injection channel
  and calling it a feature.
- Standardising the envelope is itself a contribution. No one else in this
  category has one.

## Open questions

- What client identity mechanism is appropriate for a local-only transport,
  where there is no meaningful authentication boundary between processes owned by
  the same user?
- Should the envelope be a convention in the content, a structured MCP resource
  type, or both?
