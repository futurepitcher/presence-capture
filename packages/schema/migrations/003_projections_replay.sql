-- 003: projections and replay (R3, R4)
--
-- A projection is any derived view: a text index, a vector index, a summary.
-- Entries are attributable to the capture they came from, which is the only
-- reason revocation can be proven to propagate.

CREATE TABLE projection (
  projection_name TEXT PRIMARY KEY,
  kind            TEXT NOT NULL CHECK (kind IN ('index', 'vector', 'summary')),
  created_at      TEXT NOT NULL
);

CREATE TABLE projection_entry (
  projection_name TEXT NOT NULL REFERENCES projection (projection_name),
  capture_id      TEXT NOT NULL REFERENCES capture_event (capture_id),
  entry_ref       TEXT NOT NULL,    -- backend-specific handle (row id, vector id)
  created_at      TEXT NOT NULL,
  PRIMARY KEY (projection_name, capture_id, entry_ref)
);

CREATE INDEX projection_entry_capture ON projection_entry (capture_id);

-- The receipt that a revocation reached a named projection. Without this row,
-- a conforming implementation cannot claim R3.
CREATE TABLE projection_revocation (
  projection_name TEXT NOT NULL REFERENCES projection (projection_name),
  revocation_id   TEXT NOT NULL REFERENCES revocation (revocation_id),
  applied_at      TEXT NOT NULL,
  entries_removed INTEGER NOT NULL,
  PRIMARY KEY (projection_name, revocation_id)
);

CREATE TABLE replay_watermark (
  consumer      TEXT PRIMARY KEY,
  last_sequence INTEGER NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE replay_receipt (
  consumer         TEXT NOT NULL,
  through_sequence INTEGER NOT NULL,
  state_hash       TEXT NOT NULL,   -- deterministic hash of the derived state
  created_at       TEXT NOT NULL,
  PRIMARY KEY (consumer, through_sequence)
);
