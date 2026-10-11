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
  - accessibility text ahead of OCR;
  - the plugin interfaces;
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

## What it captures

Every 5 seconds, unless paused, asleep, locked, or another user has the Mac:

| Lane | Kept as | Notes |
|------|---------|-------|
| **Screen** | `screen_text` | Each on-screen window of the front app, read by Vision. An unchanged window isn't kept again. No image is ever kept ([ADR 0005](../../docs/adr/0005-text-first-capture.md)) |
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

## The menu

| Item | What it does |
|------|--------------|
| Pause / Resume | Nothing is captured, heard or noted while paused |
| Forget the Last 15 Minutes… / Forget the Last Hour… | A revocation of that stretch, erased from disk with a receipt ([ADR 0002](../../docs/adr/0002-erasable-revocation.md)). Asked first, because it can't be undone |
| Hear the Microphone / Hear System Audio | Each input device on or off |
| Edit Excluded Apps and Windows… | Your list, one fragment a line, applied within seconds. If it can't be read, nothing is captured |

Retention erases what's older than 14 days, hourly (`defaults write
org.presence-capture.app retentionDays 30` to change it). The log, in `logs/`,
holds counts only.

## Layout

| Target | What |
|--------|------|
| `CaptureStore` | The store: migrations embedded from `packages/schema/migrations` (`scripts/embed-migrations.mjs`), CryptoKit sealing, revocation that erases, retention, redaction and exclusion |
| `CaptureCore` | What can be tested without a screen: Vision OCR, which window is in front, SpeechAnalyzer transcription, utterances |
| `PresenceCapture` | The menu-bar app, its sensors and the Keychain |
| `PcapDriver` | `pcap-driver`, the [conformance driver](../../docs/spec/DRIVER.md) over `CaptureStore` |

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
