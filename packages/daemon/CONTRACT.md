# Daemon contract

What an implementation must do to be a conformant capture daemon. Written so
this package can be built on a Mac by someone who was not involved in designing
the schema.

The daemon has exactly one job: **produce a store that passes
`packages/schema/conformance`.** Nothing in this document overrides that suite.

## Platform requirements

| Need | Why |
|------|-----|
| macOS 13+, Apple Silicon | ScreenCaptureKit, VideoToolbox HEVC, Vision OCR |
| ScreenCaptureKit, **not** `CGWindowListCreateImage` | The legacy API shows no recording privacy indicator and is on a deprecation path. A capture tool that records without the indicator is not acceptable |
| AVAudioEngine | Ambient audio lane |
| Vision framework | OCR fallback |
| Screen Recording + Microphone entitlements | Requested at first run, never silently |

## Write path

Per captured artifact, in this order:

1. **Exclusion check first.** Per-application and per-input-device exclusion is
   evaluated *before* bytes exist (R8). A capture that should not have happened
   must never reach disk, not be deleted afterwards.
2. **Dedupe.** Compute `dedupe_key` over the frame; a near-identical consecutive
   frame is dropped, not stored (R7).
3. **Redact.** Secrets are filtered *before* anything reaches disk. Redaction
   after persistence is not redaction.
4. **Payload.** Write bytes, compute the SHA-256, insert `capture_payload`.
   Frames go into HEVC segments via VideoToolbox plus a frame index — not loose
   images. Budget ~50–70 GB/month at a 2-second interval.
5. **Capture event.** Insert `capture_event` with `sequence` monotonic.
   `source_url` is set only where it was actually established; otherwise `NULL`.
   It MUST NOT be inferred from content.
6. **Text.** Accessibility-API text first, Vision OCR as fallback. Record which
   in `extraction`.
7. **Derived artifacts.** A transcript is a separate `capture_event` with
   `derived_from` pointing at its audio segment, and an alignment points at the
   transcript (R10). Never inline a transcript into the audio row — that breaks
   revocation propagation.

## Transcription

- Runs on-device. Nothing leaves the machine.
- Default ASR MUST be redistributable without a gate or revenue limit. Current
  choice: **Qwen3-ASR** (Apache-2.0, 52 languages). See the
  [licensing table](README.md).
- Diarization is opt-in and never a default dependency.
- The transcript inherits the audio's `privacy_level`. It MUST NOT be assigned a
  weaker one.

## Privacy invariants

These are not features. An implementation that misses one is not conformant:

- `sacred_mode` captures are written but are unreachable through any read path.
- `privacy_level` is assigned at write time and is never mutated afterwards —
  `capture_event` is append-only, enforced by trigger.
- Revocation is the only removal mechanism. The daemon never deletes a capture
  row.
- The daemon does not serve. It writes. Serving is `packages/mcp`, and the two
  must not share a process, so a daemon bug cannot become an egress bug.

## Third parties and consent

Ambient audio records people who did not install this. The daemon provides
exclusion controls and on-device-only processing. It does not and cannot resolve
consent of non-users, and recording law varies by jurisdiction. Implementations
MUST surface that to the operator rather than burying it.

## Definition of done

1. A clean machine runs the daemon and produces a store that passes
   `packages/schema/conformance` unmodified.
2. Revoking a captured meeting removes its audio, transcript, alignment, and all
   their projection entries — verified by the suite, not by inspection.
3. First run requests permissions explicitly; denying them degrades rather than
   crashes.
4. The recording indicator is visible whenever capture is active.
