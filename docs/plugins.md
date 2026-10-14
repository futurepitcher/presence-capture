# Plugins

Plugins add to Presence Capture: new things to capture, new views derived from
what's captured. They can't weaken it. This page is the guide for someone who
wants to write one, and for someone who wants to know what a plugin can and
can't do to their data.

The design is [ADR 0007](adr/0007-plugins.md). The rule behind it: the
guarantees hold **by construction**. A plugin isn't asked to behave. What it
can't do, it can't do, whatever its author meant.

## What works today

| | Reference host (Node) | The macOS app, 0.1 |
|---|---|---|
| **Sensors** | Yes. `runSensor`, and the sensor kit | Yes. `sensors.json`, and **Approve Sensors…** in the menu |
| **Projectors** | Yes. `loadProjector` and `runProjector`, and the projector kit | **No.** The app has no projector host, and one isn't part of 0.1 |
| **Exporters** | Design only | No |

The projector story, exactly:
- The reference host runs projectors, with a kit of attacks it must refuse or
  contain. It needs Node 22.13 or later and no Mac.
- The store's side is built in both stores, Swift and JavaScript: outputs sealed
  under the source capture's key, erased by revocation, and read back through
  a grant. Both pass the same conformance suite.
- The macOS app has no host yet. It runs no projector, and keeps no embeddings
  in 0.1 ([ADR 0008](adr/0008-recall-indexes-in-memory.md), amended). ADR 0007
  plans a helper process in the app that runs WebAssembly through
  JavaScriptCore.

Exporters are accepted as design only. They're to be built alongside ADR 0006,
which covers sending outside this Mac. That ADR isn't in the repository yet.

## Sensors

A sensor is an executable, in any language, that writes **observations** to
standard output, one JSON object a line. The host reads them, runs each one
through the gate, and writes what survives.

### The contract

**The first line is a header.** It names the sensor and the protocol:

```json
{"sensor": "git-activity", "protocol": "1"}
```

A sensor name is lower-case letters, digits and hyphens. In the app, the header
must name the sensor as it's configured. A bad header stops the sensor.

**Every line after it is an observation.** Three kinds exist, the schema's
capture types. A new kind of capture needs an RFC, not a plugin.

| `kind` | Required fields | Optional |
|--------|-----------------|----------|
| `screen` | `at`, `app`, `window`, `text` | `bundle`, `url`, `extraction` (`accessibility` or `ocr`) |
| `activity` | `at`, `app`, `state` (`active`, `idle` or `locked`) | `bundle`, `window` |
| `audio` | `at`, `device` (`input` or `output`), `transcript` | `seconds` |

- `at` is an ISO 8601 UTC time ending in `Z`.
- Any observation may carry `dedupe`: text of 1 to 200 characters, a stable ID
  for what it observed, such as a commit hash.
- `url` is only for a URL the sensor really knows. Don't infer it.
- A line ends at `\n` and nowhere else. Escape U+2028 and U+2029 in text, which
  `JSON.stringify` doesn't.
- Standard error is ignored.

The shared rules are data, in
[`cases/observations.json`](../packages/schema/cases/observations.json), so every
host answers the same way.

### What the host does with each observation

The same gate that the built-in sensors use
([`gate.js`](../packages/schema/src/gate.js)). In this order:

1. **Validate.** An observation that breaks the rules is counted as `invalid` and
   dropped.
2. **Exclude.** For `screen` and `activity`, the host checks the app and window
   against the system's own screens (the lock screen, password prompts,
   notifications), Presence Capture's own windows, and your list from **Edit
   Excluded Apps and Windows…**. An excluded `screen` observation is dropped. An
   excluded `activity` one keeps its state and nothing else: `{"state": …,
   "excluded": true}`, with no app. Audio has no app or window, so it isn't
   checked.
3. **Redact.** Secrets first (private keys, tokens, API keys, `password=…`),
   then personal identifiers (emails, home folder names, card and phone numbers,
   IP addresses). Each becomes a label, such as `[API_KEY]`. The rules are in
   [`cases/redaction.json`](../packages/schema/cases/redaction.json).
4. **Deduplicate.** With `dedupe`, the observation lands once per source. The
   store keeps an HMAC of the value, under a key derived from the master key. A
   restarted sensor adds nothing it already sent, and a revoked observation
   doesn't come back.
5. **Seal and write.** The capture's source is `sensor:<name>`. The store seals
   it under a key of its own, like any capture.

Two more rules:
- **While capture is held** (paused, locked), what a sensor sends is dropped, not
  queued. In the app, the same happens while your exclusion list can't be read.
- **A capture stamped inside a revoked time range is refused**, as the store
  refuses any ([revocation.md](revocation.md)). The host counts it as `refused`.

Because every capture is `sensor:<name>`, one sensor's captures can be revoked
together, with `scope_kind = source`. The app's Forget revokes by time, which
takes in a sensor's captures like any others.

### What a sensor can't promise

A sensor needs real access to the system: git, the music player, a calendar. So it
can't be sandboxed the way a projector is. **It runs with your permissions.** The
gate guarantees what it *stores*. Nothing can guarantee what a native program does
on its own.

So a sensor runs only as approved:
- Its **pins** are the SHA-256 of its executable and of every regular file its
  command names, by absolute path. That includes an argument that is a path, and
  the path in a `--flag=path`. A directory it watches isn't code and isn't
  pinned.
- Every sensor is started in `/`, so **a relative path names nothing.** Use
  absolute paths.
- A sensor whose files change (a swapped script, an upgraded interpreter) isn't
  run again, not even after a relaunch, until it's approved again.

### Try one against the reference host

Everything below runs from `packages/schema`, on any OS, with Node 22.13 or later
and nothing to install. `WORK` is a scratch folder for the files you make.

```sh
cd packages/schema
WORK="$(mktemp -d)"
```

A whole sensor, in a few lines:

```sh
cat > "$WORK/hello-sensor.mjs" <<'EOF'
const emit = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

// The first line names the sensor and the protocol.
emit({ sensor: 'hello', protocol: '1' });

// Then one observation a line.
emit({
  at: new Date().toISOString(),
  kind: 'activity',
  app: 'Hello',
  window: 'Hello, world',
  state: 'active',
  dedupe: 'hello-1',
});
EOF
```

Check it with the sensor kit. The script's path must be absolute:

```sh
node bin/sensor-kit.js -- node "$WORK/hello-sensor.mjs"
```

**Expected output:**
```text
PASS
```

The kit fails a sensor when:
- its header is invalid;
- an observation breaks the shared rules;
- it emits nothing;
- its captures don't land as `sensor:<name>`.

The real example is [`git-activity`](../packages/plugins/git-activity/README.md),
which notes each commit as activity. It sends the commit hash as `dedupe`.

To see the gate work, run a sensor through the host yourself. Save this as
`try-sensor.mjs` in `packages/schema`:

```js
import { computePins, openStore, runSensor } from './src/index.js';

// Absolute paths: the host starts every sensor in /.
const command = [process.execPath, process.argv[2], '--once', process.argv[3]];

const pins = computePins(command);   // what a person approves
const store = openStore();           // in memory, with a key of its own
const { name, stats } = await runSensor({ command, store, pins, fragments: ['chase'] });

console.log(name, stats.appended, stats.redacted);
for (const id of stats.captureIds) console.log(store.contentText(id));
store.close();
```

Give it a repository whose commits, made in the last day, include a key in a
message:

```sh
node try-sensor.mjs "$PWD/../plugins/git-activity/sensor.mjs" /path/to/that/repo
```

**Expected output**, for a repository with two commits, "start the plan" and
"rotate ANTHROPIC_API_KEY=sk-ant-…":
```text
git-activity 2 1
{"app":"git","window":"repo — start the plan","state":"active"}
{"app":"git","window":"repo — rotate ANTHROPIC_API_KEY=[API_KEY]","state":"active"}
```

The key is replaced before anything is written. `fragments` is the exclusion
list: a commit whose window text contains `chase` would be excluded. `pins` is the
approval. Leave it out and `runSensor` runs the command as given, as the kit does.

### Run one in the app

List the sensor in `sensors.json`, in the app's home
(`~/Library/Application Support/Presence Capture/`). The executable comes first,
as an absolute path:

```json
[{ "name": "git-activity", "command": ["/opt/homebrew/bin/node", "/path/to/packages/plugins/git-activity/sensor.mjs", "/Users/you/code/repo"] }]
```

A new sensor waits. **Approve 1 Sensor…** appears in the menu. It shows the exact
command, why the sensor is waiting, and that it runs with your permissions. Approve
it, and the app writes each file's SHA-256 into `sensors.json` and starts it.

- A sensor that stops is started again a minute later. Each start checks the pins.
- The app's log holds counts only, once an hour: appended, excluded, redacted,
  invalid, refused and dropped. Never what was observed.
- A sensor is **configured, never discovered**. The app doesn't scan for them.

## Projectors

A projector builds a derived view: an index, embeddings, a summary. **It holds
nothing.** It's a pure function from one capture to its outputs, and the store
keeps the outputs.

### The contract

**The module.** A projector is a WebAssembly module that **imports nothing**. With
no imports it has no network, no files, no clock and no randomness. There is
nothing to call and nowhere to keep a copy, so the same capture always gives the
same output and replay stays deterministic.

It must:
- declare exactly one memory, with a maximum of at most 256 pages (16 MiB);
- export `memory`, `alloc(len) -> ptr` and `project(ptr, len) -> i64`.

The host calls `alloc`, writes the capture there, and calls `project`. The input is
the capture's envelope as JSON, UTF-8
([ADR 0001](adr/0001-serving-trust-boundary.md) §4.3): its content is data
written by whoever wrote the page. `project` returns the output's pointer in the
high 32 bits and its length in the low 32. The output is JSON:

```json
{"entries": [{"ref": "summary", "kind": "summary", "value": {"words": 12}}]}
```

**The manifest.** A JSON file beside the module. It names the projector, its
projection, what it reads, and what kinds it writes.

```json
{
  "projector": "word-count",
  "protocol": "1",
  "projection": { "name": "word-count", "kind": "summary" },
  "reads": { "capture_types": ["screen_text", "audio_transcript"], "privacy_levels": ["standard"] },
  "writes": { "kinds": ["summary"] }
}
```

| Field | Allowed |
|-------|---------|
| `projector` | Lower-case letters, digits and hyphens |
| `protocol` | `"1"` |
| `projection.name`, `.kind` | A name like the above, and `index`, `vector` or `summary` |
| `reads.capture_types` | One or more of `screen_frame`, `screen_text`, `audio_segment`, `audio_transcript`, `audio_alignment`, `activity` |
| `reads.privacy_levels` | One or more of `standard`, `sensitive`, `excluded`. `sacred_mode` is never grantable |
| `writes.kinds` | One or more of `text`, `vector`, `summary` |

**The limits.** Each output is checked, and one that fails is thrown away whole:
- at most 32 entries, each with a unique `ref` of 1 to 128 letters, digits and
  `:._-`;
- each `kind` is one the manifest writes;
- each `value` is JSON of at most 16 KiB, and the whole output at most 64 KiB;
- a `vector` is up to 4096 finite numbers;
- one second for each capture, by default.

### How the host runs one

[`projector-host.js`](../packages/schema/src/projector-host.js) does this:

1. **Loads what was approved.** The module's SHA-256 must be the one approved with
   its manifest. The host refuses a module that imports anything, has unbounded
   memory, or lacks the exports. What runs is compiled once from the bytes that
   were checked. Change the bytes afterward and nothing that runs changes.
2. **Reads through a grant made from the manifest.** The grant is the projector's
   own (`projector:<name>`), and no wider than the manifest. A wider one is
   refused, not narrowed. Every capture it sees is enveloped and recorded in the
   egress log under `projector:<name>`.
3. **Runs each capture in a fresh instance,** under the time limit. Nothing one
   capture leaves in memory can reach another's output or outlive its revocation.
   A module that runs over is stopped, and nothing is written for that capture.
4. **Keeps the output in the store,** sealed under the source capture's own key,
   with the capture's watermark, in one transaction. A capture is projected whole
   or not at all.

**Revocation needs no cooperation.** Revoke the capture, and the store deletes the
entry and destroys the key that sealed its output, with a receipt for the
projection ([revocation.md](revocation.md)). There's nothing in the plugin to
acknowledge.

### Try one against the reference host

The kit loads a projector as the host would, runs it over a synthetic day through a
grant made from its manifest, runs it again to check its watermark, checks what it
was served against the manifest, then revokes everything it projected.

No toolchain is needed for a first try. The repository's test helper encodes a
small module by hand. This one returns the same output for every capture. It shows
that the host and the kit work, not that a projector of yours does. (`WORK` is
the scratch folder from the sensor section.)

```sh
cat > "$WORK/stub-manifest.json" <<'EOF'
{
  "projector": "stub",
  "protocol": "1",
  "projection": { "name": "stub", "kind": "summary" },
  "reads": { "capture_types": ["screen_text", "audio_transcript"], "privacy_levels": ["standard"] },
  "writes": { "kinds": ["summary"] }
}
EOF

WASM="$WORK/stub.wasm" node --input-type=module -e '
import { writeFileSync } from "node:fs";
import { constant } from "./conformance/plugins/wasm.js";
const output = { entries: [{ ref: "summary", kind: "summary", value: { projected: true } }] };
writeFileSync(process.env.WASM, constant(JSON.stringify(output)));
'

node bin/projector-kit.js "$WORK/stub.wasm" "$WORK/stub-manifest.json"
```

**Expected output:**
```text
PASS
```

The kit fails a projector when:
- an output survives its capture's revocation, or a receipt is missing;
- a capture times out, fails, or returns invalid output;
- it reads nothing, or reads again after its watermark;
- it was served a capture type its manifest doesn't read.

To run it by hand, and see the output sealed and then erased, save this as
`try-projector.mjs` in `packages/schema`:

```js
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { openStore, grantFor, loadProjector, runProjector } from './src/index.js';
import { parseFixture, replayFixture } from './src/fake-sensor.js';

const [wasmPath, manifestPath] = process.argv.slice(2);
const bytes = new Uint8Array(readFileSync(wasmPath));
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

// An in-memory store with a key of its own, filled with a synthetic day.
const store = openStore();
replayFixture(store, parseFixture(readFileSync('fixtures/a-short-day.jsonl', 'utf8')));

// The host runs only the module whose SHA-256 was approved with the manifest.
const projector = loadProjector({
  bytes,
  manifest,
  approvedSha256: createHash('sha256').update(bytes).digest('hex'),
});

// It reads through a grant made from its manifest, and nothing wider.
const grantId = grantFor(store, manifest, { expiresAt: '2099-01-01T00:00:00Z' });
console.log(await runProjector({ store, projector, grantId }));

// What it returned is kept by the store, sealed under the capture's key.
const [{ capture_id: captureId }] = store.db.prepare('SELECT capture_id FROM projection_entry').all();
const projection = manifest.projection.name;
console.log(store.projectionOutputs({ projection, captureId }));

// Revoke the capture, and the output goes with it.
store.revoke({ scopeKind: 'capture', scopeValue: captureId });
console.log(store.projectionOutputs({ projection, captureId }));
store.close();
```

```sh
node try-projector.mjs "$WORK/stub.wasm" "$WORK/stub-manifest.json"
```

**Expected output:**
```text
{
  read: 6,
  projected: 6,
  entries: 6,
  timedOut: 0,
  failed: 0,
  rejected: 0
}
[
  { entryRef: 'summary', kind: 'summary', value: { projected: true } }
]
[]
```

The last line is the point: after the revocation, the output is gone.

A real projector is any language that compiles to a WebAssembly module with no
imports. Pin it by its hash, and check it with the kit.

Delete `try-sensor.mjs` and `try-projector.mjs` when you're done, and `$WORK`
too. They're for trying things out, not part of the repository.

## Troubleshooting

### `sensor exited without a header`

**Cause:** The sensor never ran, or wrote no header. The usual cause is a relative
path: the host starts every sensor in `/`, so `node sensor.mjs` finds nothing.
**Solution:** Use absolute paths, for the script and for any file it reads.

### `sensor not run: not approved`

**Cause:** The host was given pins and the command doesn't match them, or none were
approved. In the app, the sensor is waiting.
**Solution:** In the app, choose **Approve Sensors…**. In the reference, pass the
output of `computePins(command)`.

### `a projector may import nothing; this one imports N`

**Cause:** The module imports a function, so it could call out.
**Solution:** Build it with no imports. Nothing can replace a clock, a file or the
network. A projector that needs a model would get it from the host, as a future
host function declared in its manifest.

### `a projector's memory must declare a maximum of at most 256 pages`

**Cause:** The module's memory has no declared maximum, or one over 16 MiB.
**Solution:** Declare a maximum in the module's memory section, no larger than
256 pages.

### `not the approved module: its SHA-256 has changed`

**Cause:** The bytes aren't the ones approved with the manifest.
**Solution:** Approve the new module, by its new hash. The host never runs a module
it didn't check.

### `ERR_INPUT_TYPE_NOT_ALLOWED` when running a projector

**Cause:** The host runs each projector in a worker thread that loads an ES
module. A worker inherits Node's flags, and Node won't load a module file while
`--input-type` is set. So `node --input-type=module -e '…'` fails as soon as it
calls `runProjector`.
**Solution:** Put the code in a `.mjs` file, as `try-projector.mjs` above does.

## Where to look

| What | Where |
|------|-------|
| The decision | [ADR 0007](adr/0007-plugins.md) |
| Sensor host, gate, pins | [`sensor-host.js`](../packages/schema/src/sensor-host.js), [`gate.js`](../packages/schema/src/gate.js), [`pins.js`](../packages/schema/src/pins.js) |
| Projector host | [`projector-host.js`](../packages/schema/src/projector-host.js), [`projector-worker.js`](../packages/schema/src/projector-worker.js) |
| The macOS sensor host | [`SensorPlugins.swift`](../packages/daemon/Sources/PresenceCapture/SensorPlugins.swift), [`Gate.swift`](../packages/daemon/Sources/CaptureStore/Gate.swift), [`Pins.swift`](../packages/daemon/Sources/CaptureStore/Pins.swift) |
| The kits and what they check | [`conformance/plugins/`](../packages/schema/conformance/plugins) |
| A sensor example | [`packages/plugins/git-activity`](../packages/plugins/git-activity/README.md) |
| What revocation does to a plugin's output | [revocation.md](revocation.md) |
| Sensors in the daemon | [daemon README](../packages/daemon/README.md#sensor-plugins) |
