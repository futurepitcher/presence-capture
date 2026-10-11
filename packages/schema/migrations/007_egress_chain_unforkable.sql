-- 007: an unforkable egress chain (ADR 0001 §4.2)
--
-- Two readers in different processes could each take the same last record
-- as their prev_hash and both insert, forking the chain. Implementations
-- append inside a write-locked transaction; this makes the database refuse a
-- fork whatever an implementation does: no two records follow the same one.

CREATE UNIQUE INDEX egress_record_prev_hash ON egress_record (prev_hash);
