-- 009: a store refuses a key that isn't its own, even with nothing left in it (R11)
--
-- A store checked a master key by unwrapping one capture's data key. Once every
-- capture is revoked (everything forgotten, or retention), nothing is left to
-- check against, so any key would open it, and captures written after under the
-- wrong key would lock the right one out. So the store keeps a check of its
-- own: a known value sealed by the master key, written once by the first writer
-- to open the store after this migration, once that writer's key has been
-- checked against a capture's where there is one.
--
-- sealed: 'presence-capture key check', sealed by the master key, AAD 'key_check'.

CREATE TABLE key_check (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  sealed     BLOB NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TRIGGER key_check_no_update BEFORE UPDATE ON key_check
BEGIN
  SELECT RAISE(ABORT, 'key_check is write-once');
END;

CREATE TRIGGER key_check_no_delete BEFORE DELETE ON key_check
BEGIN
  SELECT RAISE(ABORT, 'key_check is write-once');
END;
