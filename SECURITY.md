# Security Policy

This project captures screen, audio, and activity. A vulnerability here exposes
a person's complete working record. We treat that accordingly.

## Reporting

Report privately via GitHub's **Report a vulnerability** button under the
Security tab, which opens a private advisory.

Please do not open a public issue for anything that could expose captured data.

Expect an acknowledgement within 5 working days. We will tell you what we intend
to do and when, and we will credit you unless you prefer otherwise.

## In scope

- Any path that returns capture data to a client that holds no grant for it.
- Any read path that reaches `sacred_mode` content.
- Revocation that does not propagate to a derived projection or vector index.
- Capture written to disk without its privacy classification applied.
- Payloads served outside the untrusted envelope.
- Egress that does not appear in the egress log.

## Known and documented limits

These are design limits, already public, not vulnerabilities:

- **Captured content is attacker-controlled.** Any page or document the user
  views can plant text. The untrusted envelope labels this; it cannot stop a
  credulous client from acting on it. See
  [ADR 0001](docs/adr/0001-serving-trust-boundary.md).
- **No authentication boundary between local processes** owned by the same user.
  Local transport assumes the user's own account is trusted.
- **Pre-alpha.** The threat model is incomplete by construction, which is why
  there is no network transport.

If you think one of these is worse than we have described, that is in scope —
report it.
