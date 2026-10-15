-- 011: addresses kept before the source_url rule (CONTRACT step 3) are cut to it, as far as SQL can:
-- the query and fragment go; an address of a scheme that can carry the page itself (data:,
-- javascript:, vbscript:, blob:, about:), or with no scheme:// form, goes entirely; userinfo goes;
-- and what's left is at most 2048 characters. New addresses are cleaned before they're written
-- (SourceURL.clean, cleanSourceUrl); a pattern inside an old path (an email, say) isn't redacted
-- here (docs/known-limits.md). capture_event is append-only, so its update trigger is lifted for
-- this one statement, inside the migration's transaction, and put back as it was.

CREATE TEMP TABLE source_url_fix AS
  SELECT capture_id, source_url AS s FROM capture_event WHERE source_url IS NOT NULL;

UPDATE source_url_fix SET s = substr(s, 1, instr(s, '#') - 1) WHERE instr(s, '#') > 0;
UPDATE source_url_fix SET s = substr(s, 1, instr(s, '?') - 1) WHERE instr(s, '?') > 0;
UPDATE source_url_fix SET s = NULL
  WHERE instr(s, '://') < 2
     OR substr(s, 1, 1) NOT GLOB '[a-zA-Z]'
     OR substr(s, 1, instr(s, '://') - 1) GLOB '*[^a-zA-Z0-9+.-]*'
     OR lower(substr(s, 1, instr(s, '://') - 1)) IN ('data', 'javascript', 'vbscript', 'blob', 'about');
-- Userinfo: the authority (after ://, before the first /) up to its @.
UPDATE source_url_fix
  SET s = substr(s, 1, instr(s, '://') + 2) || substr(substr(s, instr(s, '://') + 3), instr(substr(s, instr(s, '://') + 3), '@') + 1)
  WHERE s IS NOT NULL
    AND instr(substr(s, instr(s, '://') + 3), '@') > 0
    AND (instr(substr(s, instr(s, '://') + 3), '/') = 0
         OR instr(substr(s, instr(s, '://') + 3), '@') < instr(substr(s, instr(s, '://') + 3), '/'));
UPDATE source_url_fix SET s = substr(s, 1, 2048) WHERE s IS NOT NULL;
UPDATE source_url_fix SET s = NULL WHERE s = '';

DROP TRIGGER capture_event_no_update;
UPDATE capture_event
  SET source_url = (SELECT s FROM source_url_fix WHERE source_url_fix.capture_id = capture_event.capture_id)
  WHERE capture_id IN (SELECT capture_id FROM source_url_fix WHERE s IS NOT source_url);
CREATE TRIGGER capture_event_no_update BEFORE UPDATE ON capture_event
BEGIN
  SELECT RAISE(ABORT, 'capture_event is append-only: use a revocation');
END;

DROP TABLE source_url_fix;
