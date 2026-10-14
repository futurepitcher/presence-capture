-- 010: where each projection output falls in the store's order (ADR 0008)
--
-- A projector's output (a capture's embedding, say) is written after its
-- capture, often well after. A reader that follows the store by capture
-- sequence has moved past that capture by then and would never see it. So each
-- output takes a number from the store's one sequence, shared with captures
-- and revocations, and a reader follows outputs by it.
--
-- The sequence never goes backwards: captures and revocations are never
-- deleted, and an output is deleted only by a revocation, which takes a later
-- number itself. So no number is ever given twice, unlike a rowid after a
-- delete.
--
-- Outputs kept before this migration are numbered after everything else, in
-- the order they were written. An entry with no output has no number.

ALTER TABLE projection_entry ADD COLUMN output_sequence INTEGER;

UPDATE projection_entry
SET output_sequence = rowid + (
  SELECT COALESCE(MAX(s), 0) FROM (
    SELECT MAX(sequence) AS s FROM capture_event
    UNION ALL
    SELECT MAX(sequence) AS s FROM revocation
  )
)
WHERE output_sealed IS NOT NULL;

CREATE UNIQUE INDEX projection_entry_output_sequence ON projection_entry (output_sequence);
