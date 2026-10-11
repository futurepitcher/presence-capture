# ADR 0007: Plugins extend capture without reaching around its guarantees

## Status

- **Sensors:** accepted 2026-10-10. Built, with a conformance kit, hosted by
  the reference and the macOS app.
- **Projectors:** accepted 2026-10-10. Built in the reference, with a kit of
  attacks it must contain. The macOS host follows.
- **Exporters:** accepted 2026-10-10 as design. They're built with ADR 0006,
  which covers sending outside this Mac.

## Context

Projects become ecosystems when other people can add to them. Builders will
want to add:
- new things to capture (what's playing, commits, calendar events);
- new derived views (their own index, embeddings, summaries);
- new ways out (a Markdown daily note, a webhook).

Each is a way around the guarantees this project exists for, unless the
interface rules it out:
- a sensor that writes to the store directly can skip exclusion and
  redaction;
- a projector that keeps its own copy can outlive a revocation;
- a plugin that can reach the network can send what it reads anywhere.

An interface that asks plugins to behave, and has them acknowledge that they
did, is only as good as the worst plugin. **The guarantees here hold by
construction**: what a plugin can't do, it can't do, whatever its author
intended.

## Decision

### 1. Sensors

A sensor is an executable that writes **observations** to stdout, one JSON
object a line, in the format the fake sensor replays (`fixtures/README.md`).
It runs out of process, in any language.

- **It never touches the store and never sees the master key.** The host
  applies the same gate as the built-in sensors, in the same order:
  validation (`cases/observations.json`), exclusion, redaction, sealing.
- **The first line is a header**, `{"sensor": "<name>", "protocol": "1"}`, and
  it must name the sensor it was configured as.
- **Its captures carry `source = "sensor:<name>"`**, so everything from one
  sensor can be revoked at once.
- **Observations are `screen`, `activity` or `audio`,** the schema's capture
  types. A new kind of capture is an RFC, not a plugin.
- **An observation may carry `dedupe`,** a stable ID for what it observed. It's
  kept once per source, as an HMAC under the master key, so a restarted sensor
  adds nothing and a revoked observation never comes back.
- **While capture is held**, its observations are dropped, not queued.
- **A sensor told to stop that doesn't is killed** after a short grace.
- **A sensor is configured, never discovered**: on macOS, in `sensors.json`.

**What this can't promise.** A sensor needs real access to the system (git,
the music player, a calendar), so it can't be sandboxed the way a projector
is. It runs with the user's own permissions. The gate guarantees what it
*stores*; nothing can guarantee what a native program does on its own. Pin
it: before 0.1, `sensors.json` records each command's SHA-256, and a changed
executable isn't run until it's approved again.

**The sensor kit** fails a sensor when:
- its header is invalid;
- an observation fails the shared rules;
- it emits nothing;
- its captures don't land as `sensor:<name>`.

### 2. Projectors: they compute, the store keeps

A projector builds a derived view (an index, embeddings, a summary).
**It holds nothing.** It's a pure function from one capture to its outputs,
and the store keeps the outputs.

**The module**
- A projector is a **WebAssembly module that imports nothing.** With no
  imports it has no network, no files, no clock and no randomness: there's
  nothing to call and nowhere to keep a copy. The same capture always gives
  the same output, so replay stays deterministic (R4).
- It exports `memory`, `alloc(len) -> ptr` and `project(ptr, len) -> i64`,
  the last returning its output's pointer in the high 32 bits and its length
  in the low.
- Its one memory must declare a maximum, at most 256 pages (16 MiB).

**The manifest**
- A manifest beside the module names the projector, its projection (name
  and kind), what it **reads** (capture types and privacy levels;
  `sacred_mode` is never grantable), and what kinds it **writes** (`text`,
  `vector`, `summary`).
- **The approved module is pinned.** The host refuses a module whose SHA-256
  isn't the one approved with its manifest.

**Running it**
- **It reads through a grant** made from its manifest. Every capture it's
  given is enveloped and egress-logged under `projector:<name>`, and nothing
  outside its scope reaches it.
- **Every capture gets a fresh instance**, so nothing one capture leaves in
  memory can surface in another's output and outlive its revocation.
- Each capture has a time limit. A module that runs over it is stopped, and
  nothing is written for that capture.
- **Its output is validated**: at most 32 entries, each with a unique `ref`, a
  kind the manifest writes, and a JSON value of at most 16 KiB; vectors are
  finite numbers. Output that fails validation is discarded whole.

**The store keeps the outputs (migration 006).**
- Each output is sealed under its **source capture's own data key**, on the
  `projection_entry` it belongs to.
- Revoking the capture deletes the entries and their outputs in the revoking
  transaction, with the per-projection receipt (R3), and destroys the key that
  sealed them (R11).
- The forensic check scans for projection outputs like any other content.
- No acknowledgement from the plugin is needed, because there's nothing in
  the plugin to acknowledge.

**The projector kit**
- It loads a projector as the host would, runs it over a synthetic day,
  re-runs it to check its watermark, checks what it was served against its
  manifest, then revokes everything it projected. It fails the projector when:
  - an output survives;
  - a receipt is missing;
  - a capture times out, fails, or returns invalid output.
- Its tests show the host **refusing** modules that:
  - import anything;
  - have unbounded memory;
  - aren't the approved hash.
- They show it **containing** modules that:
  - never return;
  - keep state between captures;
  - return output that's oversized, malformed, or of a kind the manifest
    doesn't write.

### 3. Exporters: the only way out

An exporter sends what it reads somewhere outside the store: a webhook, a
file, another app.

- **An exporter that persists is a projector.** A Markdown daily note kept in
  the vault is a projector, with a projector's sandbox and obligations. Where
  its output must live outside the store, it's an ADR 0006 destination.
- **A reading exporter** (an MCP server, an HTTP API) reads through a grant,
  under ADR 0001's envelope and egress log.
- **A sending exporter** is a WebAssembly module whose one import is
  `send(ptr, len)`. The host binds it to a single destination the user
  approved, with that destination's own grant, rate limit and egress
  records. It's built alongside ADR 0006.

## Consequences

- Builders can add sources and derived views in any language that compiles
  to WebAssembly, or any that writes to stdout, without being able to
  weaken exclusion, redaction, erasure or the trust boundary.
- A projector can't do everything an arbitrary program can: no network
  calls, no model downloads, no clock. That's the point. A projector that
  needs a model gets it from the host, as a future host function declared in
  its manifest, not by fetching it.
- The macOS app hosts projectors through a WebAssembly runtime: JavaScriptCore's,
  or WasmKit (Apache-2.0). That dependency will be justified in its own pull
  request.
- Sensors stay the honest exception, and are pinned and approved for that
  reason.
