-- 008: an erasure that finishes after the process that started it (R11)
--
-- A revocation erases in its transaction, then truncates the write-ahead log,
-- which still holds the frames that wrote what it erased. A reader in another
-- process can hold the log past that, and the process that revoked (a
-- command-line tool, say) can exit before the reader lets go. So whether the
-- log has been truncated since is kept in the store, not in the memory of the
-- process that revoked: completed_at stays NULL until a writer truncates the
-- log, and a writer opening the store finishes whatever is pending.
--
-- A receipt from before this migration has no completed_at either, and gets
-- one the first time a writer truncates the log: only then is it true.
--
-- The receipt stays append-only but for that one stamp, made once.

ALTER TABLE erasure_receipt ADD COLUMN completed_at TEXT;

DROP TRIGGER erasure_receipt_no_update;

CREATE TRIGGER erasure_receipt_no_update BEFORE UPDATE ON erasure_receipt
WHEN NOT (
  OLD.completed_at IS NULL AND NEW.completed_at IS NOT NULL
  AND NEW.revocation_id IS OLD.revocation_id
  AND NEW.applied_at IS OLD.applied_at
  AND NEW.keys_destroyed IS OLD.keys_destroyed
  AND NEW.contents_erased IS OLD.contents_erased
  AND NEW.payloads_erased IS OLD.payloads_erased
)
BEGIN
  SELECT RAISE(ABORT, 'erasure_receipt is append-only: only completed_at is stamped, once');
END;
