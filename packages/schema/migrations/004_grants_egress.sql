-- 004: grants and egress accounting (ADR 0001 §4.1, §4.2)

CREATE TABLE grant_record (
  grant_id           TEXT PRIMARY KEY,
  client_id          TEXT NOT NULL,
  issued_at          TEXT NOT NULL,
  expires_at         TEXT NOT NULL,   -- ADR §4.1: a grant with no expiry is not issuable
  domains            TEXT NOT NULL,   -- JSON array; '*' means any classification
  time_from          TEXT,
  time_to            TEXT,
  privacy_levels     TEXT NOT NULL,   -- JSON array
  capture_types      TEXT NOT NULL,   -- JSON array
  sources            TEXT NOT NULL,   -- JSON array
  max_rows_per_query INTEGER NOT NULL CHECK (max_rows_per_query > 0),
  revoked_at         TEXT,

  -- sacred_mode is not grantable at all. Enforced by construction, not by a
  -- check in application code that someone can forget. (ADR §4.1, test T2/T4)
  CHECK (privacy_levels NOT LIKE '%sacred_mode%')
);

CREATE TABLE egress_record (
  egress_id             INTEGER PRIMARY KEY AUTOINCREMENT,
  served_at             TEXT NOT NULL,
  client_id             TEXT NOT NULL,
  grant_id              TEXT NOT NULL,
  tool                  TEXT NOT NULL,
  query_fingerprint     TEXT NOT NULL,  -- hash, not the query text (ADR §4.2)
  capture_ids           TEXT NOT NULL,  -- JSON array: exactly what left the boundary
  privacy_levels_served TEXT NOT NULL,
  row_count             INTEGER NOT NULL,
  byte_count            INTEGER NOT NULL,
  prev_hash             TEXT NOT NULL,
  record_hash           TEXT NOT NULL
);

-- Append-only and tamper-evident. A client that could edit this log could
-- audit its own cover.
CREATE TRIGGER egress_no_update BEFORE UPDATE ON egress_record
BEGIN
  SELECT RAISE(ABORT, 'egress_record is append-only');
END;

CREATE TRIGGER egress_no_delete BEFORE DELETE ON egress_record
BEGIN
  SELECT RAISE(ABORT, 'egress_record is append-only');
END;
