# ADR 0005: Capture text first; keep no pixels by default

## Status

**Accepted** — 2026-10-10. Supersedes the frame-storage contract in SCHEMA.md
and step 4 of `packages/daemon/CONTRACT.md`.

## Context

The spec planned to keep the screen as HEVC video plus a frame index: 50–70
GB a month at a 2-second interval. That figure came from a comparable
implementation that keeps everything and extracts later.

PresenceVoice's native capture app took the other path:
- it reads each window's text on device (accessibility, then Vision OCR);
- it keeps the text with each line's position;
- it skips a window whose pixels haven't changed;
- it never keeps an image.

Its consumers (attention, the day's story, search) read only text, and lost
nothing.

Pixels are the most sensitive thing a capture tool can hold, and the most
expensive. They're also the hardest to erase, because they are large, live in
files, and get copied by the filesystem.

## Decision

- **By default, the daemon keeps no pixels.** A screen capture is a
  `screen_text` event:
  - its text sealed in `capture_content` (ADR 0002);
  - `extraction = accessibility` or `ocr`;
  - with each line's box available to an implementation that wants layout.
- `screen_frame` events with image payloads stay in the schema, for an
  **opt-in keyframe buffer** after 0.1. It will have a short retention of its
  own, and its images are sealed and erased like any other payload.
- **Storage budget for the default: under 1 GB a month**, measured by the M3
  benchmark, in place of 50–70 GB.

## Consequences

- Revocation and retention have far less to erase, and nothing large in
  files by default.
- "Show me the screen at 3pm" is not possible by default. Answering it needs
  the opt-in buffer, which users enable knowing what it keeps.
- OCR quality is the ceiling on what's remembered. Accessibility text comes
  first because it's exact where apps expose it.
