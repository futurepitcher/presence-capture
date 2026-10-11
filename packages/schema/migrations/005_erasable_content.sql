-- 005: erasable content (R11, ADR 0002)
--
-- The event log stays append-only: it records that something was captured,
-- when, from where and at what privacy level. What was captured, the words
-- and the bytes, moves out of it into tables that revocation erases.
--
-- Each capture's content is sealed under its own data key. The key is stored
-- wrapped by a master key the store never writes down (the Keychain on macOS).
-- Revocation deletes the key, the sealed text and the sealed bytes in the same
-- transaction that records it, and writes an erasure receipt. A copy of the
-- content that escaped deletion, a blob on a copy-on-write filesystem or an
-- SSD remnant, is then ciphertext with no key.
--
-- Sealed values are AES-256-GCM in combined form: nonce(12) || ciphertext ||
-- tag(16), with additional authenticated data '<kind>:<capture_id>' so a sealed
-- value cannot be moved to another capture.

-- Content no longer lives in the log. 0.x carries no migration path for stores
-- holding plaintext; see the stability statement in SCHEMA.md.
ALTER TABLE capture_event DROP COLUMN content_text;

CREATE TABLE capture_key (
  capture_id  TEXT PRIMARY KEY REFERENCES capture_event (capture_id),
  wrapped_key BLOB NOT NULL,   -- data key sealed by the master key, AAD 'key:<capture_id>'
  created_at  TEXT NOT NULL
);

CREATE TABLE capture_content (
  capture_id  TEXT PRIMARY KEY REFERENCES capture_event (capture_id),
  text_sealed BLOB NOT NULL,   -- extracted text, AAD 'text:<capture_id>'. Attacker-controlled
  created_at  TEXT NOT NULL
);

-- Where a payload's bytes live when the store keeps them itself. An
-- implementation MAY keep them in files instead (storage_uri says where), but
-- they are sealed the same way and erased the same way.
CREATE TABLE payload_blob (
  payload_hash TEXT PRIMARY KEY REFERENCES capture_payload (payload_hash),
  sealed       BLOB NOT NULL   -- AAD 'payload:<capture_id>'
);

-- The receipt that a revocation reached the content itself, as
-- projection_revocation is for derived views. A revocation with no erasure
-- receipt is non-conformant.
CREATE TABLE erasure_receipt (
  revocation_id     TEXT PRIMARY KEY REFERENCES revocation (revocation_id),
  applied_at        TEXT NOT NULL,
  keys_destroyed    INTEGER NOT NULL,
  contents_erased   INTEGER NOT NULL,
  payloads_erased   INTEGER NOT NULL
);

CREATE TRIGGER erasure_receipt_no_update BEFORE UPDATE ON erasure_receipt
BEGIN
  SELECT RAISE(ABORT, 'erasure_receipt is append-only');
END;

CREATE TRIGGER erasure_receipt_no_delete BEFORE DELETE ON erasure_receipt
BEGIN
  SELECT RAISE(ABORT, 'erasure_receipt is append-only');
END;

-- Keys and content are never rewritten in place. They are written once and
-- removed only by revocation.
CREATE TRIGGER capture_key_no_update BEFORE UPDATE ON capture_key
BEGIN
  SELECT RAISE(ABORT, 'capture_key is write-once: revoke to remove');
END;

CREATE TRIGGER capture_content_no_update BEFORE UPDATE ON capture_content
BEGIN
  SELECT RAISE(ABORT, 'capture_content is write-once: revoke to remove');
END;
