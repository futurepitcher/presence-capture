# `presence-capture-daemon`

macOS reference implementation. Captures screen, ambient audio, and activity into
a conformant store — and transcribes the audio, because raw audio is not data
anyone can use.

## Status

Pre-alpha, not yet extracted. Phase P4 on the [roadmap](../../ROADMAP.md).

## Planned design

- **Screen:** ScreenCaptureKit, in-process. Not `CGWindowListCapture` — it
  provides no recording privacy indicator and is on a deprecation path.
- **Audio:** AVAudioEngine, ambient lane.
- **Transcription:** on-device. Nothing leaves the machine.
- **Activity:** window, application, and input-idle signals.
- **Text:** accessibility-API text first, Apple Vision OCR as fallback.
- **Privacy:** redaction before anything reaches disk; per-application and
  per-input-device exclusion; frame dedupe.

Its only job is to produce a store that passes the conformance suite.

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
| **Qwen3-ASR** (0.6B / 1.7B) | Apache-2.0, 52 languages | **Default ASR** |
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
