# RFC 0000: A sensor's privacy floor, and an extraction for app stores

- **Status:** Draft
- **Author:** Presence Capture maintainers
- **Opened:** 2026-11-18
- **Affects:** spec | shared cases

## Summary

Let the host's configuration of a sensor, never the sensor itself, raise the
privacy level of everything that sensor captures to `sensitive`. And add
`app_store` to the extractions a `screen` observation may name, for text a
sensor read from an app's own local data rather than from the screen.

## Motivation

A sensor that reads private conversations (the draft WhatsApp sensor,
[docs/sources/whatsapp.md](../docs/sources/whatsapp.md)) lands every message
as `standard` today, because the gate sets `standard` for every sensor
capture. A grant that reads `standard`, which is the default, then serves
those messages to an agent. The spec already has the right level:
`sensitive`, "flagged private by the user or a rule; not grantable by
default". There's no way for a sensor's captures to reach it.

Separately, `screen.extraction` is `accessibility` or `ocr`, and the gate
defaults to `ocr`. A message read from an app's database is neither, so the
record misstates how it was captured.

## Design

**Privacy floor.**
- A sensor's configuration (on macOS, its entry in `sensors.json`) may carry
  `"privacy_level": "sensitive"`. Absent, it's `standard`, as today.
- The host applies it in the gate, to every capture the sensor's
  observations produce. It's part of what the person approves: changing it
  needs approving again.
- An observation can't set or lower its own level. A field named
  `privacy_level` on an observation makes it invalid.
- `sacred_mode` and `excluded` aren't allowed as a floor: `sacred_mode`
  never leaves the device by design, and `excluded` is the gate's own.

**Extraction.**
- `screen.extraction` may be `accessibility`, `ocr` or `app_store`.
- `app_store` means the text was read from the app's own local data, not
  from what was on screen.

## Conformance

- `cases/observations.json`: an observation carrying `privacy_level` is
  invalid; `extraction: "app_store"` is valid.
- Sensor kit and host tests: a sensor configured `sensitive` lands every
  capture `sensitive`; a default grant reads none of them; a grant naming
  `sensitive` reads them; revoking `privacy_level = sensitive` erases them.

## Privacy and security

It only ever raises a level, and only the host can set it, so a sensor can't
use it to widen what's served. It narrows what default grants serve.

## Alternatives

- A grant with `sources` that leave the sensor out. It works today, but it
  puts the burden on every grant, and the default grant still reads it.
- A `message` capture type with sender and chat. Cleaner, and a much larger
  change. This RFC doesn't block it.

## Compatibility

Additive. Stores and hosts that don't know the field keep landing captures as
`standard`, as now.
