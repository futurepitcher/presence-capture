# Fixtures

Recorded sensor observations, replayed by the fake sensor
(`src/fake-sensor.js`). They let anyone fill a store and work on the store,
search, MCP and evals without a Mac, permissions or a microphone.

```sh
node bin/replay-fixture.js --store /tmp/day.sqlite --master-key-file /tmp/master.key fixtures/a-short-day.jsonl
```

## Format

JSON Lines. The first line is a header. Each line after it is one thing a
sensor observed, **before** exclusion and redaction:

```json
{"fixture": "a-short-day", "version": 1, "platform": "macos", "exclusion_list": "Chase\n", "description": "..."}
{"at": "2026-10-06T09:00:05.000Z", "kind": "screen", "app": "Cursor", "bundle": "…", "window": "…", "url": null, "extraction": "accessibility", "text": "…"}
{"at": "…", "kind": "activity", "app": "…", "bundle": "…", "window": "…", "state": "active | idle | locked"}
{"at": "…", "kind": "audio", "id": "call-1", "device": "input | output", "seconds": 14.2, "transcript": "…"}
```

- `exclusion_list` is the user's list, in the format `cases/exclusion.json`
  parses.
- Any observation may carry `dedupe`: a stable ID for what it observed, such
  as a commit hash. The store keeps it once per source, even after a
  revocation.
- `url` is set only where a real sensor could establish it. It's never
  inferred from the text.
- An audio observation becomes an `audio_segment` with no stored audio (text
  first, ADR 0005), plus an `audio_transcript` derived from it (R10).

Fixtures are synthetic. Never commit a recording of a real person's screen or
voice.
