# ADR 0007: Plugins extend capture without reaching around its guarantees

## Status

- **Sensors: Accepted** (2026-10-10), implemented with a conformance kit.
- **Projectors and exporters: Proposed.** No code until this section is
  accepted, because they read sealed content.

## Context

Projects become ecosystems when other people can add to them. Builders will
want to add new things to capture (what's playing, commits, calendar events),
new derived views (their own index or embeddings), and new ways out (a
Markdown daily note, a webhook).

Each of these is a way around the guarantees this project exists for, unless
the interface prevents it:
- A sensor that writes to the store directly can skip exclusion and
  redaction.
- A projector that keeps its own copy can outlive a revocation.
- An exporter that writes files makes copies no revocation reaches.

## Decision

Three extension points. Each is held to a conformance kit, as an
implementation is held to the store layer.

### 1. Sensors (accepted)

A sensor is an executable that writes **observations** to stdout, one JSON
object a line, in the format the fake sensor replays (`fixtures/README.md`).
It runs out of process, in any language.

- **It never touches the store and never sees the master key.** The host
  applies the same gate as the built-in sensors, in the same order: exclusion,
  then redaction, then sealing. An observation the gate excludes is never
  written; one that fails validation is dropped and counted.
- **The first line is a header:** `{"sensor": "<name>", "protocol": "1"}`. The
  name is lower-case letters, digits and hyphens.
- **Its captures carry `source = "sensor:<name>"`**, so everything from one
  sensor can be revoked at once (`scope_kind = source`).
- **Observations are `screen`, `activity` or `audio`,** the capture types the
  schema already has. A new kind of capture is an RFC, not a plugin.
- **While capture is held** (paused, locked, asleep), the host drops a
  sensor's observations rather than queueing them.
- **A sensor is configured, never discovered.** On macOS it's listed in
  `sensors.json` in the app's home, with its full command.

The **sensor kit** (`packages/schema/conformance/plugins`) runs a sensor and
fails it when:
- its header is invalid;
- any observation fails `cases/observations.json`'s rules;
- it emits nothing;
- its observations, put through the gate into a store, don't land as
  `sensor:<name>` captures.

### 2. Projectors (proposed)

A projector builds a derived view (an index, embeddings, a summary) from
events, by watermark. It reads content, so:

- it reads through a **grant**, like any other reader: enveloped and
  egress-logged;
- it **registers a projection** and adds `projection_entry` rows for what it
  keeps, so revocation knows what to prune;
- on revocation, the host sends it the revoked capture IDs. It must remove
  them from its own storage and **acknowledge with a count**, which becomes the
  `projection_revocation` receipt. Without an acknowledgement the receipt
  isn't written, and the revocation reports that projection as outstanding.

Its kit revokes captures the projector holds and fails it when the
acknowledgement is missing, or when its own storage still answers for them.

### 3. Exporters (proposed)

An exporter serves reads to something outside: a webhook, a file, another
app.
- **An exporter that persists anything is a projector**, and takes on a
  projector's obligations. A Markdown daily note is a projector.
- An exporter that doesn't persist reads through a grant, like the MCP server,
  under ADR 0001's envelope and egress log.

## Consequences

- Builders can add sources in an afternoon, in any language, without being
  able to weaken exclusion, redaction or erasure.
- Projectors and exporters wait on this ADR's acceptance. They're where an
  ecosystem would most easily leak, so they come with their kits or not at
  all.
- The observation format becomes a contract. `cases/observations.json` holds
  the reference host and the macOS daemon to the same validation.
