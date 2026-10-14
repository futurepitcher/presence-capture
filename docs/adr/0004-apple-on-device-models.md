# ADR 0004: On macOS, use Apple's on-device models wherever possible

## Status

**Accepted** — 2026-10-10. Applies to `packages/daemon` and the macOS app.

**Amended** — 2026-10-14: 0.1 ships no speech fallback for macOS 14–15, so
hearing needs macOS 26 (a non-goal of the 0.1.0 release plan). The
`SFSpeechRecognizer` fallback below is for a later release.

## Context

The daemon README chose **Qwen3-ASR** as the default speech recogniser,
because a default dependency must be redistributable with no account gate and
no revenue limit. That rule stands.

Meanwhile PresenceVoice's native capture app shipped a working pipeline on
Apple's own frameworks:
- Vision OCR, line by line with positions;
- **SpeechAnalyzer** for the microphone and system audio, one utterance a row.

Apple's models ship with the OS, run on device, and need nothing
redistributed. They satisfy the rule more completely than any bundled model,
and they cost the user no download and no extra disk.

## Decision

On macOS, the default for each job is the Apple framework:

| Job | Default | Fallback |
|-----|---------|----------|
| Screen text | Accessibility text, then **Vision** `RecognizeTextRequest` | — |
| Speech to text | **SpeechAnalyzer** + `SpeechTranscriber` (macOS 26) | `SFSpeechRecognizer`, on-device only (macOS 14–15; not in 0.1) |
| Embeddings | None in 0.1. Apple's sentence and contextual embeddings were measured and found worse than keyword search (ADR 0008, amended) | A small open Core ML model, if it beats keyword search on the eval |
| Language ID | `NLLanguageRecognizer` | — |
| Session labels, digests | **Foundation Models** (on-device, macOS 26 with Apple Intelligence) | templates from app, window title and top terms |
| Content sealing | **CryptoKit** AES-GCM; master key in the **Keychain** | — |

- Recognition never falls back to a network service:
  - `SFSpeechRecognizer` is used only with `requiresOnDeviceRecognition`;
  - a request that can't run on device fails rather than leaving the Mac.
- Each embedding is stored with its model identifier and dimension, so
  changing models re-projects instead of mixing vector spaces.
- Qwen3-ASR, Whisper and whisper.cpp remain in the licensing table as
  optional engines. **Windows** chooses its own defaults in its own ADR,
  under the same rule.

## Consequences

- No model download, account or network call in the default install.
  (Amended 2026-10-14: on macOS 26 the speech model for the person's language
  is downloaded by macOS, once, from Apple, the first time hearing or dictation
  needs it. No account is involved, and recognition stays on the device.)
- **Features degrade with the OS rather than failing.** Without macOS 26 or
  Apple Intelligence, transcription uses the older on-device recogniser, and
  digests use templates. (Amended 2026-10-14: not in 0.1, where hearing needs
  macOS 26; screen and activity capture work from macOS 14.)
- Embedding quality is whatever Apple's model gives. The M3 eval decides
  whether that's good enough, against a published recall@5 target. The
  fallback is a small Core ML model, still on device.
- Apple can change these frameworks between OS releases. Each one sits behind
  a protocol in the daemon (`Transcriber`, `Embedder`, `Labeller`), so a
  replacement is one conformance-tested implementation, not a rewrite.
