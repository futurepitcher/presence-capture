# ADR 0002: Revocation erases content, provably

## Status

**Accepted** — 2026-10-10. Implemented in migration `005` and enforced by
`conformance/forensic.test.js` (R11) and `conformance/mutation.test.js`.

## 1. Context

Until migration 005, revocation was a read filter. A revoked capture was
listed in `revoked_capture`, its projection entries were pruned with a receipt,
and every read path excluded it. But its text lived in
`capture_event.content_text`, and `capture_event` is append-only by trigger
(R1). The words a user revoked stayed in `store.sqlite` forever.

The forensic check proves it. On `cc4eab1`, a capture holding
`MY-BANK-PIN-4417` was revoked, and the string was still in the database
file afterwards.

The project's central claim is that revocation provably reaches derived data.
A claim that stops short of the data itself is not one we can make.

There are two requirements in tension:

- **R1:** the log is append-only and auditable. Nobody, including the store,
  can quietly rewrite what was captured.
- **Forgetting:** when the user revokes something, its content is gone from
  disk, beyond recovery by anyone holding the files *and* the key.

## 2. Decision

**Split what was captured from the record that it was captured.**

1. `capture_event` keeps metadata only: when, what type, from where, at what
   privacy level, derived from what. It stays append-only. `content_text` is
   dropped from it.
2. Content moves to tables that revocation erases:
   - `capture_content.text_sealed`: the extracted text;
   - `payload_blob.sealed`: payload bytes, when the store keeps them itself.
     An implementation MAY keep them in files instead; they are sealed and
     erased the same way.
3. **Every capture's content is sealed under its own data key**:
   - AES-256-GCM, in combined form: `nonce(12) ‖ ciphertext ‖ tag(16)`. This
     is CryptoKit's `SealedBox.combined`, so Swift and JS stores are
     byte-compatible.
   - Additional authenticated data `text:<capture_id>` or
     `payload:<capture_id>`, so a sealed value cannot be moved to another
     capture.
4. **The data key is stored wrapped by a master key** in `capture_key`, with
   AAD `key:<capture_id>`. The store never writes the master key. On macOS it
   lives in the Keychain. The reference implementation takes it as an
   argument. A store refuses to open with the wrong master key.
5. **Revocation, in the same transaction that records it:**
   - deletes the revoked captures' sealed payloads, sealed text and keys;
   - writes an `erasure_receipt` with the counts.

   After commit, it runs `wal_checkpoint(TRUNCATE)`. The store runs with
   `secure_delete = ON`, so deleted cells are zeroed, not left on a free
   page.
6. **A revocation with no erasure receipt is non-conformant**, as one with no
   projection receipt already was (R3).

### Why a key per capture, if the ciphertext is deleted too?

Because deletion is only as good as the medium:
- A blob file on APFS may survive in a snapshot or a copy-on-write extent.
- A Time Machine backup, or SSD wear levelling, can keep bytes we asked the
  filesystem to remove.

The key is a few dozen bytes in one SQLite page that we *can* overwrite. Once
it's gone, any surviving copy of the ciphertext is noise. The data is gone
twice: deleted, and unreadable if the deletion missed a copy.

### Why not per-capture keys for the log too?

The metadata is the audit trail. It's the thing that lets a user (and the
egress log) say "an agent read a capture from Notes at 14:02 on Tuesday", even
after the content is gone. Sealing it would make revocation unprovable rather
than more private.

## 3. Consequences

- **R1 changes meaning.** Payloads are content-addressed over their *sealed*
  bytes. Identical bytes in two captures are stored twice, because a shared
  payload could not be erased for one capture alone. Cross-capture dedup of
  payloads is gone. Near-duplicate suppression *before* persistence (R7) is
  unaffected.
- **`contains` matching moves above SQL.** The reference reader unseals only
  rows the grant already admits, then matches. Full-text search becomes a
  projection (`fts`) whose rows revocation deletes in the same transaction:
  M3's work, under R3.
- **A new requirement, R11**, is tested by a forensic check. It runs a store
  in a real directory, revokes an audio capture and its transcript, then scans
  every file the store left: the database, WAL, SHM and any blob directory.
  It looks for:
  - plaintext, which must never appear, revoked or not;
  - the revoked captures' wrapped keys and sealed bytes, which must be gone;
  - anything the master key can still decrypt, where the revoked content must
    be absent and an unrevoked control capture present.
- **The check is itself tested.** Six mutant stores, each with one erasure
  step broken from outside, must each fail it:
  - keys survive;
  - sealed text survives;
  - the sealed payload survives;
  - `secure_delete` is off;
  - the WAL is never truncated;
  - no receipt is written.
- **0.x carries no migration path** for a store already holding plaintext in
  `content_text`. Migration 005 drops the column, as the stability statement
  in SCHEMA.md allows.

## 4. Limits, stated plainly

- **Backups taken before a revocation** hold the wrapped key and the
  ciphertext. Anyone with that backup *and* the master key can still read
  them. Rotating the master key (re-wrapping every live data key, then
  destroying the old master) closes this, and is future work. Until then,
  "erased" means erased from this store and every copy made after the
  revocation.
- **Metadata stays.** Capture type, time, source app, source URL where
  established, privacy level and payload size all remain. A URL can be
  revealing on its own. Revoking a source (`scope_kind = source`) erases
  content, not the record that the source was used.
- **Process memory.** Content unsealed for a read lives in memory until it is
  garbage-collected. The reference implementation doesn't scrub it.
- **A reader holding the write-ahead log** (an MCP server mid-read) blocks its
  truncation, so the revoked bytes stay in the log until the reader lets go.
  The revocation still takes effect at once: the keys are gone from the
  database, and every read path excludes the captures. The store reports the
  erasure as not yet done on disk (`erasedOnDisk: false`), and finishes it as
  soon as it can.
- **SSD and filesystem remnants of SQLite pages** are below what
  `secure_delete` can reach. The key-per-capture design is what covers them,
  not a claim about the hardware.
