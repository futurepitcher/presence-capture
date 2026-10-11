# Conformance Driver Protocol

**Version:** 1
**Status:** Normative for v0.1.

The store-layer suite (`packages/schema/conformance/store`) checks an
implementation without using its API. It starts the implementation's
**driver**, an executable that speaks this protocol, and asks it to write
and revoke. Then it reads the store's files directly, as
[SCHEMA.md](SCHEMA.md) defines them.

If your implementation passes the store-layer suite, it's conformant, in any
language.

```sh
PRESENCE_CAPTURE_DRIVER="/path/to/your-driver --flags" npm run conformance:store
```

Unset, the suite drives the reference driver
(`packages/schema/bin/driver.js`).

## Transport

- The driver reads requests from **stdin** and writes responses to
  **stdout**, one JSON object per line, UTF-8.
- **A line ends at `\n` and nowhere else.** A reader MUST NOT also split on
  `\r` alone, or on U+2028 or U+2029. Node's `readline` does, and
  `JSON.stringify` leaves those characters unescaped, so captured text holding
  one would cut a message in two. A writer SHOULD escape U+2028 and U+2029 as
  `\u2028` and `\u2029`. The same framing holds for sensor plugins and for
  MCP over stdio.
- One request at a time. Every request gets exactly one response, in order.
- stderr is free for the driver's own logging. The suite passes it through.
- The driver opens no socket.
- It exits when stdin closes.
- A driver is a test fixture. It accepts the master key in the clear, which a
  production implementation never would. Don't ship it enabled.

```json
{"id": 1, "op": "append", "args": {"capture_type": "screen_text", "source": "screen", "privacy_level": "standard", "content_text": "hello"}}
{"id": 1, "ok": true, "result": {"capture_id": "cap_…"}}
{"id": 2, "ok": false, "error": {"code": "constraint", "message": "…"}}
```

## Error codes

| Code | Meaning |
|------|---------|
| `constraint` | The schema refused the write: an unknown privacy level, a duplicate `dedupe_key`, or a write to an append-only table |
| `key` | The master key doesn't open this store |
| `denied` | A read the grant doesn't allow: no grant, or a revoked or expired one (ADR 0001) |
| `bad_request` | An unknown op, missing arguments, or no store is open |
| `internal` | Anything else |

The suite checks codes, never messages.

## Operations

All fields are `snake_case`, matching the column names in SCHEMA.md. Optional
fields may be omitted or `null`.

| Op | Args | Result |
|----|------|--------|
| `hello` | — | `{protocol: "1", implementation}` |
| `open` | `path`, `master_key_hex` (64 hex chars) | `{}`. Creates the store when `path` doesn't exist. Fails with `key` when the store exists and the key doesn't open it |
| `append` | `capture_type`, `source`, `privacy_level`; optional `capture_id`, `captured_at`, `source_app`, `source_url`, `classification`, `content_text`, `payload: {bytes_base64, media_type}`, `extraction`, `derived_from`, `dedupe_key` | `{capture_id}` |
| `register_projection` | `name`, `kind` (`index`, `vector`, `summary`) | `{}` |
| `add_projection_entry` | `projection`, `capture_id`, `entry_ref`; optional `output_kind` and `output_json`, the output kept sealed under the capture's key | `{}` |
| `revoke` | `scope_kind`, `scope_value`; optional `reason` | `{revocation_id, revoked_capture_ids, erased_on_disk}`, including captures reached through `derived_from`. `erased_on_disk` is false while a reader holds the write-ahead log and the revoked bytes may still be in it |
| `retain` | `days`; optional `now` (ISO 8601, for tests) | As `revoke`, or `{revocation_id: null, revoked_capture_ids: []}` when nothing was old enough |
| `issue_grant` | `client_id`, `expires_at`; optional `privacy_levels`, `capture_types`, `sources`, `domains`, `time_from`, `time_to`, `max_rows_per_query` | `{grant_id}`. Fails with `constraint` for a grant naming `sacred_mode` |
| `revoke_grant` | `grant_id` | `{}` |
| `read` | `grant_id`, `tool`; optional `query`, `contains`, `limit`, `after_sequence` | `{envelopes}`, as ADR 0001 defines them, in sequence order, each served row recorded in the egress log. Fails with `denied` for a missing, revoked or expired grant |
| `content` | `capture_id` | `{text}`, the capture's text as the implementation unseals it, or `null` |
| `payload` | `capture_id` | `{bytes_base64}`, or `null` |
| `close` | — | `{}` |

## What the suite reads directly

After driving writes, the suite opens the store file **read-only** with
SQLite. It expects the tables and the sealing format of SCHEMA.md
(migrations `001`–`005`).

Payload bytes are read from `payload_blob`, or from a file named by
`capture_payload.storage_uri` in the form `file:<path relative to the store's
directory>`.

It also scans **every file under the store's directory** for plaintext and
for the sealed bytes of revoked captures. It does this while the driver still
has the store open. Keep everything the store writes (WAL, blobs, sidecars)
under that directory, or the forensic check can't vouch for it.

## Versioning

The protocol carries its own version, reported by `hello`. Adding an op or an
optional field is a minor change. Changing or removing either needs an RFC
and a new version.
