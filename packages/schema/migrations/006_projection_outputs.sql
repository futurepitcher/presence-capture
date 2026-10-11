-- 006: projection outputs (R3, R11, ADR 0007)
--
-- A projector computes; the store keeps what it computed. Each output sits on
-- the projection_entry it belongs to, sealed under the data key of the
-- capture it was derived from, with AAD
-- 'projection:<projection_name>:<capture_id>:<entry_ref>'.
--
-- Revoking the capture deletes its projection entries (with their outputs) in
-- the revoking transaction, with the per-projection receipt R3 already
-- requires, and destroys the key that sealed them (R11). Nothing derived from
-- a capture lives anywhere that revocation doesn't reach.

ALTER TABLE projection_entry ADD COLUMN output_kind TEXT
  CHECK (output_kind IS NULL OR output_kind IN ('text', 'vector', 'summary'));
ALTER TABLE projection_entry ADD COLUMN output_sealed BLOB;
