-- 001: capture core (R1, R5, R6, R7, R9, R10)
--
-- Capture events are append-only. Payloads are content-addressed and stored
-- separately from metadata, so bulk bytes never sit in the index.

CREATE TABLE capture_payload (
  payload_hash  TEXT PRIMARY KEY,          -- sha256 hex over the bytes (R1)
  byte_count    INTEGER NOT NULL,
  media_type    TEXT NOT NULL,
  storage_uri   TEXT NOT NULL,             -- where the bytes actually live
  created_at    TEXT NOT NULL
);

CREATE TABLE capture_event (
  capture_id     TEXT PRIMARY KEY,
  sequence       INTEGER NOT NULL UNIQUE,  -- monotonic; the replay ordering (R4)
  captured_at    TEXT NOT NULL,
  capture_type   TEXT NOT NULL
    CHECK (capture_type IN (
      'screen_frame', 'screen_text', 'audio_segment',
      'audio_transcript', 'audio_alignment', 'activity'
    )),
  source         TEXT NOT NULL,            -- source family, platform-neutral (R9)
  source_app     TEXT,                     -- bundle id / executable, if known
  source_url     TEXT,                     -- NULL when not establishable, never guessed
  privacy_level  TEXT NOT NULL
    CHECK (privacy_level IN ('standard', 'sensitive', 'excluded', 'sacred_mode')),
  classification TEXT,                     -- opaque to the schema (R6)
  payload_hash   TEXT REFERENCES capture_payload (payload_hash),
  content_text   TEXT,                     -- extracted text, if any
  extraction     TEXT
    CHECK (extraction IS NULL OR extraction IN ('accessibility', 'ocr', 'asr', 'none')),
  derived_from   TEXT REFERENCES capture_event (capture_id),  -- projections chain (R10)
  dedupe_key     TEXT                      -- near-identical frame collapsing (R7)
);

CREATE INDEX capture_event_captured_at ON capture_event (captured_at);
CREATE INDEX capture_event_privacy     ON capture_event (privacy_level);
CREATE INDEX capture_event_derived     ON capture_event (derived_from);
CREATE UNIQUE INDEX capture_event_dedupe
  ON capture_event (dedupe_key) WHERE dedupe_key IS NOT NULL;

-- Append-only, enforced by the database rather than by convention (R1).
-- A delete cannot demonstrate that derived data went too; that is what
-- revocation is for (R2).
CREATE TRIGGER capture_event_no_update BEFORE UPDATE ON capture_event
BEGIN
  SELECT RAISE(ABORT, 'capture_event is append-only: use a revocation');
END;

CREATE TRIGGER capture_event_no_delete BEFORE DELETE ON capture_event
BEGIN
  SELECT RAISE(ABORT, 'capture_event is append-only: use a revocation');
END;
