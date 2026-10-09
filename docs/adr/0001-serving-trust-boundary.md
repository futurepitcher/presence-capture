# ADR 0001: Serving capture over MCP inverts the trust boundary

## Status

**Accepted** — 2026-10-09

Supersedes the Proposed draft of 2026-10-09. This ADR gates `packages/mcp`: no
serving code ships until the four decisions below are implemented and the
conformance tests in §7 pass.

## 1. Context

The prevailing posture for MCP is that it is an adapter boundary, not a trust
model. Tool output is untrusted input. New servers begin quarantined and
read-only. Credentials are scoped to the adapter and never reach workers.

That posture describes a **client consuming servers**. This project is the other
end of the wire, and the inversion is total:

| | Consuming | Serving (this project) |
|---|---|---|
| Untrusted party | The server | **The client** |
| Asset at risk | The host's actions and credentials | **A complete record of a person's screen and audio** |
| Content origin | The server's operator | **Every third party whose text appeared on the user's screen** |

The third row is the one without precedent. A capture store holds data whose
*provenance* we trust completely — we recorded it ourselves, we know when and
from which application — and whose *meaning* we cannot trust at all, because the
content was authored by whoever made the page the user happened to be reading.

**Conflating those two properties is this category's central mistake.** A store
can be perfectly auditable and still be a weapon.

## 2. Threat model

### 2.1 Assets

In rough order of severity if compromised:

1. **Capture payloads** — frames, audio segments, transcripts, extracted text.
2. **Derived projections** — embeddings, summaries, alignments, indices. These
   leak the same information in a form that is easier to query at scale.
3. **The grant configuration** — write access to it is equivalent to write
   access to every asset above.
4. **The egress log** — reveals which clients saw what, and is the only record
   that would expose a past compromise.
5. **Exclusion rules** — silently disabling one turns a consent boundary off
   without any visible signal.

### 2.2 Adversaries

**A1 — Third-party content authors. In scope, and the novel one.**
Anyone who can get text in front of the user: a web page, a document, an email,
a Slack message, a code comment, a filename. They do not need access to the
machine. They need the user to look at something once. Their capability is to
place arbitrary text into the capture store, correctly attributed and faithfully
recorded, with no compromise anywhere in the pipeline. **This adversary is always
present and cannot be excluded.** Assume every capture contains hostile text.

**A2 — A credulous but honest agent client. In scope, highest expected
frequency.** An editor, assistant, or agent framework holding a legitimate
grant. It is not malicious; it simply treats retrieved text as instructions
because that is what language models do. A1 supplies the payload, A2 supplies
the capability. This pairing is the primary attack, and it requires no attacker
skill beyond writing a convincing paragraph.

**A3 — A malicious or compromised local client. In scope.**
A rogue dependency inside an otherwise trusted tool, a hostile editor extension,
or a plain malicious MCP client the user installed. Capability: issues arbitrary
tool calls under whatever identity it claims.

**A4 — A local process under the same user account. Partially in scope.**
Can read the store on disk, can impersonate any client identity (§6.1), and with
root can tamper with the egress log. Mitigations here are detective, not
preventive.

**A5 — Network attackers. Out of scope in v1, by construction.**
There is no listener. This is the main reason v1 has no remote transport.

### 2.3 Trust zones

```
  content authored by A1          ← NEVER trusted (meaning)
          │
          ▼
  capture daemon                  ← trusted code, writes only
          │
          ▼
  capture store                   ← trusted provenance, untrusted content
          │
          ▼
  MCP server (packages/mcp)       ← trusted code, enforces the boundary
          │   ▲
          │   └── grants + egress log  ← trusted, not servable
          ▼
  MCP client                      ← NEVER trusted (A2, A3)
```

The boundary that matters is the single arrow out of the MCP server. Everything
in this ADR exists to make that one arrow accountable.

### 2.4 Named attack chains

**C1 — Injection to action.** A1 publishes a page containing text shaped like
instructions. The user views it. The daemon captures it, OCR or accessibility
extraction lifts the text verbatim, it is embedded and indexed. Later the user
asks their agent a question whose retrieval surfaces that capture. The agent
reads the planted text as part of its context and acts on it — writing a file,
calling another tool, sending a message.

The capture pipeline did nothing wrong at any step. That is what makes this hard.
Mitigated by §4.3 and §4.4; **not solved** — see §6.2.

**C2 — Exfiltration by breadth.** A3 holds a narrow, legitimate grant and issues
thousands of small queries, reconstructing far more of the store than the grant
was intended to permit. v1 **detects** this via §4.2 rather than preventing it;
`max_rows_per_query` raises the cost without closing the hole.

**C3 — Classification bleed.** A capture classified `standard` quotes or displays
content that was itself `sensitive` — a password manager visible behind a browser
window, a private message pasted into a public document. Classification is applied
per capture event, so the derived capture carries the weaker level. Residual risk,
documented in §6.3.

**C4 — Grant confusion.** Two local clients present the same identity, or A4
presents another client's identity. On a local transport there is no
cryptographic boundary between processes owned by the same user. v1 treats client
identity as **advisory for attribution, not authoritative for authorisation**
(§6.1).

**C5 — Log tampering.** A4 edits or truncates the egress log to hide a read.
Mitigated by append-only writes and a hash chain (§4.2); a local root user can
still rewrite the chain. Detectable on verification, not preventable.

## 3. Decision summary

1. Read scopes are enforced below the tool layer. Default deny.
2. Every served row is accounted for in a user-queryable, append-only log.
3. All served capture content is wrapped in a declared untrusted envelope.
4. v1 is read-only and local-transport-only.

## 4. Decisions in detail

### 4.1 Scopes are enforced below the tool layer

A privacy level is a guarantee, not a tag. Enforcement lives in the repository
layer, beneath every tool handler, so that **no tool implementation, prompt, or
client argument can route around it**. A tool handler that forgets to filter
still cannot over-serve, because the layer it calls will not return the rows.

A grant is the only thing that authorises a read:

| Field | Meaning |
|-------|---------|
| `grant_id` | Stable identifier, referenced by every egress record |
| `client_id` | Who it was issued to. Advisory for attribution (§6.1) |
| `issued_at`, `expires_at` | Grants expire. A grant with no expiry is not issuable |
| `domains[]` | Classification values readable under this grant |
| `time_range` | Absolute or rolling window of capture timestamps |
| `privacy_levels[]` | Subset of `standard`, `sensitive`, `excluded` |
| `capture_types[]` | e.g. screen text, audio transcript, activity |
| `sources[]` | Application or source-family allowlist |
| `max_rows_per_query` | Raises the cost of C2 |
| `revoked_at` | Revocation is immediate and retroactively visible in the log |

Defaults, which are the part that actually matters:

- **A client with no grant receives nothing.** Not an empty result that looks
  like a successful query — an explicit authorisation failure, logged.
- `sensitive` and `excluded` are **not grantable by default**. Granting either
  requires an explicit user action per level, per client.
- **`sacred_mode` is not grantable at all.** It is absent from the enum above
  deliberately: there is no value a grant can hold that admits it. This is
  enforced by construction rather than by a check, and §7 requires a test that
  fails if it ever becomes reachable through any read path.

### 4.2 Egress accounting

Without a record of what was served, "local-first" is a marketing claim rather
than a property anyone can verify. The user must be able to answer: *what has
this tool read about me?*

One append-only record per served response:

| Field | Meaning |
|-------|---------|
| `served_at` | Timestamp |
| `client_id`, `grant_id` | Attribution, and the authority relied upon |
| `tool` | Which tool served it |
| `query_fingerprint` | Hash of the query, not the query text |
| `capture_ids[]` | Exactly which captures left the boundary |
| `privacy_levels_served[]` | So a `sensitive` read is visible at a glance |
| `row_count`, `byte_count` | For spotting C2 |
| `prev_hash`, `record_hash` | Hash chain over the preceding record |

Rules:

- The log is **append-only**. No update or delete path exists in the serving code.
- The log is **not servable over MCP**. It is an asset (§2.1), and a client that
  can read it can audit its own cover.
- Revoking a grant does **not** redact past records. The user needs to know what
  was already read.
- `query_fingerprint` rather than the query itself, because queries about a
  person's capture history are themselves sensitive.

### 4.3 The untrusted-payload envelope

Captured content is attacker-controlled (A1). It is therefore never returned as
bare text that a client might concatenate into a prompt. Every payload crossing
the boundary is wrapped:

```json
{
  "presence_capture_untrusted": {
    "envelope_version": "1",
    "provenance": {
      "capture_id": "cap_01J...",
      "captured_at": "2026-10-09T14:22:31Z",
      "source_app": "com.google.Chrome",
      "source_url": "https://example.com/post/42",
      "capture_type": "screen_text",
      "privacy_level": "standard",
      "extraction": "accessibility"
    },
    "content": "…verbatim captured text…"
  }
}
```

Normative rules:

- A conforming server **MUST NOT** return capture content outside this wrapper.
- `content` is **data, never instructions**. A conforming client **MUST NOT**
  treat it as a directive, and **SHOULD** render it to its model inside a
  delimited, clearly-labelled region.
- `provenance` is populated by the daemon at capture time, never derived from the
  content, so that a document claiming to be from elsewhere cannot forge it.
- `source_url` is present only where the daemon could establish it; absence is
  reported as `null`, never guessed.

The envelope is the one piece of this ADR we would like other implementations to
adopt, whatever else they do differently. It costs clients a little integration
effort and gives them the one thing they currently lack: a way to tell, from the
protocol rather than from a guess, that the bytes they are holding came from an
untrusted author.

### 4.4 Read-only, local-only

- **No mutations.** A client cannot write capture state, issue grants, modify
  exclusions, or write to the log. No capture event originates from a tool call.
- **Local transport only.** No network listener in v1, which removes A5 entirely
  and buys time to get C1 right.

Both are design positions rather than backlog items. A pull request adding either
will be declined with a pointer to this section.

## 5. Consequences

- `packages/mcp` cannot ship until §4.1–§4.4 exist and §7 passes. Hard gate.
- Clients must handle the envelope to get usable content, raising integration
  cost. Accepted: the alternative is shipping an injection channel and describing
  it as a feature.
- Remote and multi-client transports are deferred publicly and for a stated
  reason, which we expect to be a differentiator rather than a gap.
- The egress log grows with use and needs its own retention contract — deferred
  to the schema spec, not to the serving layer.
- A second implementation can adopt the envelope without adopting our grant
  model, and still interoperate. That is intentional.

## 6. What this does not solve

Stating these plainly is part of the decision. A threat model that only lists
victories is marketing.

### 6.1 Local client identity is advisory

On a local transport, processes owned by the same user can impersonate one
another. `client_id` is therefore reliable for **attribution in the common case**
and not reliable as an **authorisation boundary against A3 or A4**. We do not
claim otherwise. Making it authoritative needs an OS-level mechanism we have not
designed, and pretending otherwise would be worse than the gap.

### 6.2 The envelope labels the problem; it does not fix it

A client that chooses to concatenate `content` into a prompt is not prevented
from doing so by anything the server can emit. C1 remains live against any
credulous client. What the envelope buys is: the client cannot claim it had no
way to know, and a careful client has everything it needs to do the right thing.
Server-side mitigation of C1 is an open research problem, not a feature we are
withholding.

### 6.3 Classification is per event, so bleed is possible

C3 is not addressed in v1. A `standard` capture that happens to display
`sensitive` content carries the weaker level. Addressing it needs content-aware
classification, which is a model-quality problem rather than a schema problem.

### 6.4 Detection, not prevention, for breadth and tampering

C2 and C5 are made **visible** rather than impossible. For a local-first system
whose adversary may hold the machine, we think visibility is the honest ceiling,
and we would rather say so than imply a guarantee.

## 7. Conformance requirements

`packages/mcp` is not releasable until these exist and pass:

| # | Test | Must fail when |
|---|------|----------------|
| T1 | No-grant read | A client without a grant receives any capture row |
| T2 | `sacred_mode` unreachable | Any read path returns a `sacred_mode` capture |
| T3 | Scope filtering below tools | A tool handler that omits filtering over-serves |
| T4 | Default non-grantability | A grant is issued for `sensitive` or `excluded` without explicit per-level consent |
| T5 | Grant expiry | An expired or revoked grant serves a row |
| T6 | Egress completeness | A served row is absent from the log |
| T7 | Log append-only | An update or delete against the log succeeds |
| T8 | Log not servable | Any tool returns egress records |
| T9 | Envelope coverage | Capture content is returned outside the envelope |
| T10 | Provenance integrity | `provenance` is derived from content rather than capture metadata |
| T11 | Read-only | Any tool call mutates capture state, grants, or exclusions |
| T12 | Hash chain | A tampered log record verifies successfully |

T2, T6 and T9 are the three that distinguish this project. If they are weakened,
the project has lost its reason to exist.

## 8. Open questions

- Should the envelope be a convention in content, a structured MCP resource type,
  or both? Leaning both: the JSON shape above for structured clients, plus a
  delimiter convention for clients that flatten everything to text.
- What is the retention contract for the egress log, given it grows without
  bound and is itself sensitive?
- Is there an OS-level identity mechanism on macOS worth building on to close
  §6.1 — code signature of the connecting process, for instance — or does that
  create a false sense of a boundary that a determined A4 still walks through?
