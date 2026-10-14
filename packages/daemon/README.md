# `presence-capture-daemon`

The macOS reference implementation: a menu-bar app that reads the screen, hears
this Mac and notes what's in front, into a store whose content is sealed and
whose revocation erases. It writes and never serves. Agents read the store
through `packages/mcp`, a separate process.

## Status

Pre-alpha, in progress (M2 on the [roadmap](../../ROADMAP.md)).
- The store passes the store-layer conformance suite through `pcap-driver`.
- The app captures screen, audio and activity into that store.
- Not yet done:
  - projector and exporter plugins (proposed in ADR 0007);
  - a live side-by-side parity trial against screenpipe.

## Build, test, run

You need macOS 14 or later, with Xcode 26 or later for the macOS 26 SDK.

```sh
cd packages/daemon
swift test                     # the store, the shared cases, OCR, utterances, on-device transcription
./build.sh                     # .build/app/Presence Capture.app, signed with your Apple Development identity if you have one
open ".build/app/Presence Capture.app"
```

Check the store against the spec:

```sh
swift build --product pcap-driver
cd ../schema && PRESENCE_CAPTURE_DRIVER="$(swift build --package-path ../daemon --show-bin-path)/pcap-driver" npm run conformance:store
```

The app asks for nothing at launch. Screen Recording, the microphone and
Accessibility (for a browser's page address) are each asked for from its menu,
when you choose. The store is in `~/Library/Application Support/Presence
Capture/` (set `PRESENCE_CAPTURE_HOME` to move it). Its master key is in the
Keychain, on this device only, never synced.

The bundle ID is `ai.presenceos.capture`. macOS ties the app's permissions,
settings and Keychain item to it, so a build under another ID
(`PRESENCE_CAPTURE_BUNDLE_ID`) starts afresh. A fork should use its own.

## What it captures

Every 5 seconds, unless paused, asleep, locked, or another user has the Mac:

| Lane | Kept as | Notes |
|------|---------|-------|
| **Screen** | `screen_text` | Each on-screen window of the front app. The focused one is read from the app's own Accessibility text where it exposes enough (exact, no OCR): only what's visible, never a password field. The rest are read by Vision OCR. An unchanged window isn't kept again. No image is ever kept ([ADR 0005](../../docs/adr/0005-text-first-capture.md)) |
| **Audio** (macOS 26) | `audio_segment` + `audio_transcript` | The microphone and system audio, each of which can be turned off. Transcribed on device by SpeechAnalyzer ([ADR 0004](../../docs/adr/0004-apple-on-device-models.md)), one utterance at a time, stamped when it was said. No audio is kept |
| **Activity** | `activity` | The app, window and state (active, idle after 2 minutes, locked), written only when one changes |

Before anything is written, in this order ([CONTRACT.md](CONTRACT.md)):
1. Excluded apps and windows are never read: the system's own UI, this app,
   and your list (Edit Excluded Apps and Windows…).
2. Secrets and personal identifiers are redacted
   ([shared cases](../schema/cases/README.md)).
3. Content is sealed under a key of its own.

An excluded window still passes time, so activity keeps its state alone, never
what it was.

## Sensor plugins

Anything else worth noting (commits, what's playing, a calendar) can be added
as a [sensor plugin](../../docs/adr/0007-plugins.md): an executable, in any
language, that writes observations to stdout. List it in `sensors.json` in the
app's home:

```json
[{ "name": "git-activity", "command": ["/opt/homebrew/bin/node", "/path/to/packages/plugins/git-activity/sensor.mjs", "/Users/you/code/repo"] }]
```

It runs only as you approved it. A new sensor, or one whose executable or
script has changed since, waits under **Approve Sensors…** in the menu, which
shows exactly what will run. Approving records each file's SHA-256 in
`sensors.json`.

Its observations pass the same gate as the built-in sensors': exclusion, then
redaction, then sealing. It never touches the store or the key. While capture
is held, what it sends is dropped. Its captures are `sensor:<name>`, so they
can be revoked together. Check one with the
[sensor kit](../schema/conformance/plugins/sensor-kit.js):

```sh
node ../schema/bin/sensor-kit.js -- node "$PWD/../plugins/git-activity/sensor.mjs" --once ~/code/repo
```

The sensor's path must be absolute: the host starts every sensor in `/`.

## `pcap-mcp`, the native MCP server

[ADR 0008](../../docs/adr/0008-recall-indexes-in-memory.md)'s reader:
- It's launched by an MCP client over stdio, and it's inside the app bundle.
- It reads through a grant: enforced in `CaptureStore`, enveloped, and
  recorded in the hash-chained egress log.
- **SQLite refuses every write it might make except an egress record**
  (`restrictToReading`), so a bug in it can't touch a capture, a key or a
  grant.
- It passes the same MCP conformance as the reference.

```sh
swift build --product pcap-mcp
"/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp" --grant <grant_id>     # the app's store and key
pcap-mcp --check                                                                   # opens it as a reader, prints counts
pcap-mcp --store <path> --grant <grant_id> --master-key-file <path>                # any other store (tests)
```

Run from inside the app's bundle, `pcap-mcp` opens the app's store with the
master key from the Keychain, and nothing asks. The key is kept in a
**versioned** item (`store.shared.v<N>`, `MasterKeyItem` in `CaptureStore`)
whose access list, set when it's made, trusts the app and the readers in its
bundle by their code signatures. When a reader is added, the version goes up,
and the app makes the new item from the newest older one, with the same key,
at its next launch: an access list is never changed, because changing one
makes macOS ask for authorization, sometimes again and again. Only the
person's default (login) keychain is searched, so a locked keychain left on
the search list (a build's signing keychain) never prompts. Version 1 trusts
the app and `pcap-mcp`; version 2 adds `pcap`.

## `pcap`, the command line

A writer to the store, as the app is, and in its bundle, so the Keychain item
trusts it. What it shows of what agents read is counts and metadata, never
content.

```sh
P="/Applications/Presence Capture.app/Contents/MacOS/pcap"   # Homebrew links it as pcap
"$P" connect claude-code        # or claude-desktop, cursor: a grant, and pcap-mcp in its config
"$P" grant add my-agent --types screen_text,activity --days 7
"$P" grant list [--all]
"$P" grant revoke <grant_id>
"$P" egress [--days 7]          # what each agent was given, by day, tool and type
"$P" forget 15m                 # or 1h, 90m, …: revoke the stretch just past, and erase it
"$P" check                      # the key, the file's structure, the egress chain, erasures
```

`connect` gives the agent a grant of its own (standard captures of every
type, for 30 days, unless `--types`, `--levels` or `--days` say otherwise) and
adds `pcap-mcp`, by its absolute path, with that grant and the store's
absolute path (and `--master-key-file`, when one was given), to the agent's
MCP config as `presence-capture`. It shows the change and asks before writing
(`--yes` doesn't ask; `--dry-run` only shows), copies the config aside first,
beside itself, and revokes the grant of any entry it replaces. A grant whose
config wasn't written, because the answer was no or the write failed, is
revoked again; one that can't be revoked is reported, with the command that
revokes it in its own store. A config that changes while the change is on
screen is shown again, as it is now, before anything is written; two
connections take turns, and neither waits more than ten seconds for the other
or a minute for `claude`. With `CLAUDE_CONFIG_DIR` set, Claude Code keeps its
settings where this can't be sure of finding them, so `connect claude-code`
refuses: add the entry by hand.

| Client | Config | How it's changed |
|--------|--------|------------------|
| Claude Code | `~/.claude.json`, user scope | `claude mcp remove` and `claude mcp add-json`, Claude Code's own commands; the file is only read |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | the file, with every other key kept; quit and reopen Claude Desktop |
| Cursor | `~/.cursor/mcp.json` | the file, with every other key kept |

By hand, the entry is the same for each (Claude Desktop's has no `type`).
With no `--store`, `pcap-mcp` opens the app's store:

```json
"presence-capture": {
  "type": "stdio",
  "command": "/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp",
  "args": ["--grant", "<grant_id from pcap grant add>"]
}
```

`pcap forget` is the menu's Forget, from the command line. The running app
isn't told, so the app it was in front of is noted again at the next change,
not at once.

## The menu

| Item | What it does |
|------|--------------|
| Pause / Resume | Nothing is captured, heard or noted while paused |
| Forget the Last 15 Minutes… / Forget the Last Hour… | A revocation of that stretch, erased from disk with a receipt ([ADR 0002](../../docs/adr/0002-erasable-revocation.md)). Asked first, because it can't be undone |
| Connect an Agent → Claude Code… / Claude Desktop… / Cursor… | What `pcap connect` does: a grant of its own for 30 days, and `pcap-mcp` in the agent's MCP config. The change is shown, with its diff, and asked about; the config is copied aside first |
| Agents Read… | Every agent's grant, with Withdraw…, and what each was given, day by day, by tool and kind: counts from the egress log, never content |
| Hear the Microphone / Hear System Audio | Each input device on or off |
| Keep Captures For → 1 Day … 1 Year | Retention (ADR 0003). A shorter period erases what's older at once, so it's asked first, and it's kept only once that's revoked: if the store can't, the period stays as it was |
| Edit Excluded Apps and Windows… | Your list, one fragment a line, applied within seconds. If it can't be read, nothing is captured |
| Set Up Presence Capture… | The first-run window, again: each permission, what it's for, and connecting an agent |
| Check for Updates… | Asks GitHub for the latest release and offers its page if it's newer. Only when chosen: it's the one request the app makes |

The first launch opens the set-up window. Nothing is asked for until its
button is pressed; allowing the microphone there also turns on Hear the
Microphone.

Retention erases what's older than 14 days unless Keep Captures For says
otherwise, hourly. The log, in `logs/`, holds counts only.

## Dictation (experimental)

On macOS 26, hold a key and speak, in any app: what you say is typed where the
cursor is, transcribed on this Mac by the same `Transcriber` ambient audio
uses. It's experimental in 0.1: its limits are in
[docs/known-limits.md](../../docs/known-limits.md#dictation). It's off until you turn it on (Dictation in the menu, or the set-up
window), which asks for its permissions then: the microphone, Input Monitoring
for the key, and Accessibility to type.

- **The key.** Fn (Globe) by default, or Right Option or Right Command. The
  event tap is listen-only and asks for modifier changes (`flagsChanged`)
  alone: it never sees a key typed. A press under a quarter second is an
  ordinary press. If macOS does something of its own with the Globe key, the
  set-up window says so and offers another key; it never changes the setting.
- **It always ends.** Released, or cancelled: held past 120 s, the screen
  locking, sleep, another user, Pause, turning it off, or a permission taken
  away. A release macOS never delivers is caught by reading the key while it's
  held. A cancelled dictation types and keeps nothing.
- **What's typed.** "New line", "new paragraph", "period", "comma" and
  "question mark" become what they name. With Tidy What I Say (and Apple
  Intelligence), the on-device model may remove fillers and false starts and
  fix punctuation, and its text is used only if that's all it changed; never in
  a terminal or code editor. It goes in through Accessibility where the field
  takes it, else by pasting, with your clipboard put back after 750 ms unless
  something else copied meanwhile. If the window or field changed since you
  pressed the key, nothing is typed: the panel keeps the words, with Copy. A
  password field gets nothing.
- **What's kept.** With Remember What I Dictate (on by default), what was
  dictated is kept as an `audio_transcript` with source `dictation`, stamped at
  key-down, redacted, and forgettable like any capture. Not from an excluded
  app or window, a password field, a cancelled dictation, or while paused.
  Ambient audio drops what the microphone heard while you dictated, so nothing
  is kept twice.

## Layout

| Target | What |
|--------|------|
| `CaptureStore` | The store: migrations embedded from `packages/schema/migrations` (`scripts/embed-migrations.mjs`), CryptoKit sealing, revocation that erases, retention, redaction and exclusion |
| `CaptureCore` | What can be tested without a screen: Vision OCR, which window is in front, SpeechAnalyzer transcription, utterances |
| `PresenceCapture` | The menu-bar app, its sensors and the Keychain |
| `PcapDriver` | `pcap-driver`, the [conformance driver](../../docs/spec/DRIVER.md) over `CaptureStore` |
| `CaptureRecall` | Recall ([ADR 0008](../../docs/adr/0008-recall-indexes-in-memory.md)): the reader's in-memory index and its six tools |
| `PcapMCP` | `pcap-mcp`, the native MCP server over `CaptureRecall` |
| `CaptureConnect` | Connecting an agent: its grant, and `pcap-mcp` in its MCP config, shown and confirmed first. Shared by `pcap connect` and the menu |
| `PcapCLI` | `pcap`, the command line |

## Transcripts are projections, not captures

A transcript is derived from an audio payload, so revoking the audio must revoke
the transcript, its alignment, and its embeddings. The conformance suite tests
this. If you implement transcription another way, that property still has to hold.

## Model licensing constraints

This is an Apache-2.0 project, so a default dependency cannot be gated behind a
third-party account or limited by the adopter's revenue. Someone who clones this
must be able to run it.

| Component | Licence | Role |
|-----------|---------|------|
| **Apple SpeechAnalyzer** / on-device `SFSpeechRecognizer` | Ships with macOS; nothing redistributed | **Default ASR on macOS** ([ADR 0004](../../docs/adr/0004-apple-on-device-models.md)) |
| Qwen3-ASR (0.6B / 1.7B) | Apache-2.0, 52 languages | Optional, and a candidate default off macOS |
| Whisper large-v3-turbo | MIT | Optional high-accuracy finalizer |
| whisper.cpp | MIT | Optional runtime |
| WhisperX (code) | BSD-2-Clause | Optional alignment stage |
| WhisperX / pyannote diarization models | Gated — Hugging Face account, per-model terms acceptance, token. `speaker-diarization-community-1` weights are CC-BY-4.0, commercial use permitted **with attribution** | **Opt-in only.** Never a default |
| Moonshine, English models | MIT | Optional low-latency English lane |
| Moonshine, non-English models | Reported as a community licence free only below $1M revenue — **unverified** | Not usable as a default until the official text is confirmed |

If you add a model dependency, put it in this table with its licence, or the PR
will be sent back.

## Third parties and consent

Ambient audio records people who did not install this. Consent of non-users is
the operator's responsibility, and recording law varies by jurisdiction. The
daemon provides exclusion controls and on-device-only processing; it does not and
cannot make that problem go away.
