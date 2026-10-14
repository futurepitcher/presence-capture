# ADR 0004: On macOS, use Apple's on-device models wherever possible

## Status

**Accepted** — 2026-10-10. Applies to `packages/daemon` and the macOS app.

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
| Speech to text | **SpeechAnalyzer** + `SpeechTranscriber` (macOS 26) | `SFSpeechRecognizer`, on-device only (macOS 14–15) |
| Embeddings | **NaturalLanguage** `NLEmbedding.sentenceEmbedding` (chosen over `NLContextualEmbedding` by measurement: ADR 0008, amended) | A small Apache-licensed Core ML model if the eval demands it |
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
- **Features degrade with the OS rather than failing.** Without macOS 26 or
  Apple Intelligence, transcription uses the older on-device recogniser, and
  digests use templates.
- Embedding quality is whatever Apple's model gives. The M3 eval decides
  whether that's good enough, against a published recall@5 target. The
  fallback is a small Core ML model, still on device.
- Apple can change these frameworks between OS releases. Each one sits behind
  a protocol in the daemon (`Transcriber`, `Embedder`, `Labeller`), so a
  replacement is one conformance-tested implementation, not a rewrite.
