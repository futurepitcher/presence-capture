-- 002: revocation (R2, R3)
--
-- Revocation is an event. The materialised set below is what read paths and
-- projection pruning consult.

CREATE TABLE revocation (
  revocation_id TEXT PRIMARY KEY,
  sequence      INTEGER NOT NULL UNIQUE,
  revoked_at    TEXT NOT NULL,
  scope_kind    TEXT NOT NULL
    CHECK (scope_kind IN ('capture', 'time_range', 'source', 'privacy_level')),
  scope_value   TEXT NOT NULL,
  reason        TEXT
);

CREATE TABLE revoked_capture (
  capture_id    TEXT PRIMARY KEY REFERENCES capture_event (capture_id),
  revocation_id TEXT NOT NULL REFERENCES revocation (revocation_id),
  revoked_at    TEXT NOT NULL,
  cascaded      INTEGER NOT NULL DEFAULT 0  -- 1 when revoked via derived_from (R10)
);

CREATE TRIGGER revocation_no_update BEFORE UPDATE ON revocation
BEGIN
  SELECT RAISE(ABORT, 'revocation is append-only');
END;

CREATE TRIGGER revocation_no_delete BEFORE DELETE ON revocation
BEGIN
  SELECT RAISE(ABORT, 'revocation is append-only: a revocation cannot be unmade');
END;
