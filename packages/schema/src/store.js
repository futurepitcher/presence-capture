import { createHash, createHmac, hkdfSync, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { migrate } from './migrate.js';
import { cleanSourceUrl } from './redact.js';
import { newKey, seal, unseal } from './seal.js';

const ENVELOPE_VERSION = '1';
const GENESIS_HASH = '0'.repeat(64);
const EPOCH = '0000-01-01T00:00:00.000Z';

const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const now = () => new Date().toISOString();

/**
 * A time as the store writes it: ISO 8601 UTC with milliseconds. Every time
 * the store compares as text (captured_at against a revocation's range) is in
 * this form, so "...05Z" can't sort after "...05.999Z" and slip out of a range.
 */
function canonicalTime(value, what) {
  const date = new Date(value);
  if (typeof value !== 'string' || Number.isNaN(date.getTime())) throw new Error(`${what} must be an ISO 8601 time`);
  return date.toISOString();
}

/** SQL true when a time_range scope_value is two canonical times: compared as text. */
const CANONICAL_RANGE = `(length(scope_value) = 49 AND substr(scope_value, 25, 1) = '/'
  AND substr(scope_value, 20, 1) = '.' AND substr(scope_value, 24, 1) = 'Z'
  AND substr(scope_value, 45, 1) = '.' AND substr(scope_value, 49, 1) = 'Z')`;

/** A time_range's bounds, each in that form. */
function canonicalRange(value) {
  const bounds = typeof value === 'string' ? value.split('/') : [];
  if (bounds.length !== 2) throw new Error('time_range is from/to, each an ISO 8601 time');
  return bounds.map((b, i) => canonicalTime(b, i === 0 ? 'time_range from' : 'time_range to')).join('/');
}

const KEY_CHECK = 'presence-capture key check';

/**
 * Refuses a master key that isn't the store's (migration 009). Against the
 * store's own key check; where there's none yet, against a capture's key, and
 * then the check is written, so a store with every capture revoked still knows
 * its key. Written with INSERT OR IGNORE and read back, so of two writers
 * opening it at once, the one whose key differs is refused.
 */
function checkKey(db, masterKey) {
  const refuse = () => { throw new Error('masterKey does not open this store'); };
  const opens = (sealed, aad, expected) => {
    try {
      const value = unseal(masterKey, sealed, aad);
      return expected === undefined || value.toString('utf8') === expected;
    } catch {
      return false;
    }
  };
  let check = db.prepare('SELECT sealed FROM key_check WHERE id = 1').get();
  if (!check) {
    const probe = db.prepare('SELECT capture_id, wrapped_key FROM capture_key LIMIT 1').get();
    if (probe && !opens(probe.wrapped_key, `key:${probe.capture_id}`)) refuse();
    db.prepare('INSERT OR IGNORE INTO key_check (id, sealed, created_at) VALUES (1, ?, ?)')
      .run(seal(masterKey, Buffer.from(KEY_CHECK), 'key_check'), now());
    check = db.prepare('SELECT sealed FROM key_check WHERE id = 1').get();
  }
  if (!opens(check.sealed, 'key_check', KEY_CHECK)) refuse();
}

/** Raised when a read is attempted without sufficient authority. */
export class AuthorizationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AuthorizationError';
  }
}

/**
 * Raised when a write would bring back what a revocation forgot: a capture
 * stamped inside a revoked time range, or derived from a revoked capture, or
 * a projection entry for a revoked capture.
 */
export class RevokedError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RevokedError';
  }
}

/**
 * Open a conformant capture store.
 *
 * Content is sealed under a per-capture key wrapped by `masterKey`, which the
 * store never writes down. An ephemeral store makes its own; a file store
 * must be given the one it was created with.
 *
 * @param {string} [path] file path, or ':memory:' for an ephemeral store
 * @param {{masterKey?: Buffer, onTruncated?: () => void}} [options]
 *   `onTruncated` is for tests: it runs after the log is truncated and before
 *   the erasures that proves are stamped, so a test can commit another writer's
 *   revocation in between.
 */
export function openStore(path = ':memory:', { masterKey, onTruncated } = {}) {
  if (!masterKey) {
    if (path !== ':memory:') throw new Error('a file store needs its masterKey');
    masterKey = newKey();
  }
  if (masterKey.length !== 32) throw new Error('masterKey must be 32 bytes');

  // Keys dedupe values (dedupeKeyFor) so a dedupe_key, which outlives a
  // revocation in the append-only log, can't be matched to what it named
  // without the master key.
  const dedupeSecret = Buffer.from(hkdfSync('sha256', masterKey, Buffer.alloc(0), 'presence-capture dedupe', 32));

  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys = ON');
  // Another process (the daemon, another reader) may hold the write lock for a
  // moment: wait for it rather than fail.
  db.exec('PRAGMA busy_timeout = 5000');
  // Deleted content is overwritten, not left on a free page (R11).
  db.exec('PRAGMA secure_delete = ON');
  // A REPLACE deletes the row it replaces; with this, that delete meets the triggers that refuse
  // one, so an append-only record can't be rewritten in place.
  db.exec('PRAGMA recursive_triggers = ON');
  // What a revocation reaches is worked out in a temp table: kept in memory, never in a file outside the store's directory.
  db.exec('PRAGMA temp_store = MEMORY');
  // A new store is switched to WAL by whichever writer gets there first, and
  // SQLite tells the other it's locked at once rather than after its busy
  // timeout: so that one waits here, as long as the timeout would have.
  for (let waited = 0; ; waited += 20) {
    try {
      db.exec('PRAGMA journal_mode = WAL');
      break;
    } catch (err) {
      if ((err.errcode & 0xff) !== 5 || waited >= 5000) {
        db.close();
        throw err;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    }
  }
  migrate(db);

  // Fail at open, not on some later read, when the key is not this store's.
  try {
    checkKey(db, masterKey);
  } catch (err) {
    db.close();
    throw err;
  }

  /**
   * Runs fn under the write lock, taken before anything is read (BEGIN
   * IMMEDIATE), so nothing another writer commits can fall between what fn
   * reads and what it writes. Another writer may be the daemon, the command
   * line, or an MCP server writing its egress record.
   */
  function immediate(fn) {
    db.exec('BEGIN IMMEDIATE');
    try {
      const result = fn();
      db.exec('COMMIT');
      return result;
    } catch (err) {
      db.exec('ROLLBACK');
      throw err;
    }
  }

  const nextSequence = () => {
    const { seq } = db
      .prepare(`
        SELECT COALESCE(MAX(s), 0) + 1 AS seq FROM (
          SELECT MAX(sequence) AS s FROM capture_event
          UNION ALL
          SELECT MAX(sequence) AS s FROM revocation
          UNION ALL
          SELECT MAX(output_sequence) AS s FROM projection_entry
        )
      `)
      .get();
    return seq;
  };

  // ---------------------------------------------------------------- writes

  /**
   * Append a capture. Its text and payload bytes are sealed under a key of its
   * own before they are written, and the event, key, content and payload are
   * written in one transaction, so a capture never exists half-sealed.
   *
   * The payload hash is over the sealed bytes: content-addressed for
   * integrity. Identical bytes in two captures are stored twice, because a
   * shared payload could not be erased for one capture alone (ADR 0002).
   */
  function appendCapture(event) {
    return immediate(() => appendLocked(event));
  }

  /**
   * Append several captures in one transaction: all of them or none. A later
   * one can name an earlier one as `derivedFrom` by the `captureId` it was
   * given, so an audio segment and its transcript land together, and a
   * duplicate segment (its dedupe_key) or a failed transcript leaves nothing.
   */
  function appendAll(events) {
    return immediate(() => events.map(appendLocked));
  }

  function appendLocked(event) {
    const captureId = event.captureId ?? `cap_${randomUUID()}`;
    const dataKey = newKey();
    const createdAt = now();
    const capturedAt = event.capturedAt == null ? createdAt : canonicalTime(event.capturedAt, 'capturedAt');
    if (event.derivedFrom != null && event.derivedFrom === captureId) throw new Error('constraint: a capture cannot be derived from itself');
    refuseForgotten(capturedAt, event.derivedFrom);

    let payloadHash = null;
    if (event.payload) {
      const sealed = seal(dataKey, Buffer.from(event.payload.bytes), `payload:${captureId}`);
      payloadHash = sha256(sealed);
      db.prepare(`
        INSERT INTO capture_payload (payload_hash, byte_count, media_type, storage_uri, created_at)
        VALUES (?, ?, ?, ?, ?)
      `).run(payloadHash, sealed.length, event.payload.mediaType, `payload_blob:${payloadHash}`, createdAt);
      db.prepare('INSERT INTO payload_blob (payload_hash, sealed) VALUES (?, ?)').run(payloadHash, sealed);
    }

    db.prepare(`
      INSERT INTO capture_event (
        capture_id, sequence, captured_at, capture_type, source, source_app,
        source_url, privacy_level, classification, payload_hash,
        extraction, derived_from, dedupe_key
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      captureId,
      nextSequence(),
      capturedAt,
      event.captureType,
      event.source,
      event.sourceApp ?? null,
      // Kept in plain metadata, which Forget leaves: scheme, host and path only, redacted.
      cleanSourceUrl(event.sourceUrl),
      event.privacyLevel,
      event.classification ?? null,
      payloadHash,
      event.extraction ?? null,
      event.derivedFrom ?? null,
      event.dedupeKey ?? null,
    );

    db.prepare('INSERT INTO capture_key (capture_id, wrapped_key, created_at) VALUES (?, ?, ?)')
      .run(captureId, seal(masterKey, dataKey, `key:${captureId}`), createdAt);

    if (event.contentText != null) {
      db.prepare('INSERT INTO capture_content (capture_id, text_sealed, created_at) VALUES (?, ?, ?)')
        .run(captureId, seal(dataKey, Buffer.from(event.contentText), `text:${captureId}`), createdAt);
    }
    return captureId;
  }

  /**
   * A revocation forgets what it names from then on, too. A capture stamped
   * inside a revoked time range is refused: speech written after it was said,
   * a screen read while the range was being forgotten, anything older than
   * retention. So is one derived from a revoked capture. Either would
   * otherwise arrive after the revocation and be readable.
   */
  function refuseForgotten(capturedAt, derivedFrom) {
    // A range kept in canonical form (revoke) compares as text. One a version
    // before migration 008 kept as it was given (to the second, say) is read
    // into that form here, so it forgets as much as it did when it was made.
    const forgotten = db.prepare(`
      SELECT 1 FROM revocation WHERE scope_kind = 'time_range' AND ${CANONICAL_RANGE}
        AND substr(scope_value, 1, 24) <= ? AND substr(scope_value, 26, 24) >= ?
      LIMIT 1
    `).get(capturedAt, capturedAt) !== undefined || db.prepare(`
      SELECT scope_value FROM revocation WHERE scope_kind = 'time_range' AND NOT (${CANONICAL_RANGE})
    `).all().some(({ scope_value: value }) => {
      let bounds;
      try {
        bounds = canonicalRange(value).split('/');
      } catch {
        return false; // never resolvable, so it never forgot anything
      }
      return bounds[0] <= capturedAt && bounds[1] >= capturedAt;
    });
    if (forgotten) throw new RevokedError('captured_at falls in a revoked time range');
    if (derivedFrom != null && isRevoked(derivedFrom)) throw new RevokedError('derived_from names a revoked capture');
  }

  const isRevoked = (captureId) =>
    db.prepare('SELECT 1 FROM revoked_capture WHERE capture_id = ?').get(captureId) !== undefined;

  /**
   * The dedupe_key for a value a sensor marks as already seen (a commit hash,
   * say): HMAC-SHA256 under a key derived from the master key, over
   * "<source>\u001f<value>". The same value from the same source always gets
   * the same key, so the store refuses it twice, even after the first is
   * revoked. Without the master key the key says nothing about the value.
   */
  function dedupeKeyFor(source, value) {
    return createHmac('sha256', dedupeSecret).update(`${source}\u001f${value}`).digest('hex');
  }

  /** A capture's text, unsealed; null when it has none or it was erased. */
  function contentText(captureId) {
    const row = db.prepare(`
      SELECT k.wrapped_key, c.text_sealed FROM capture_content c
      JOIN capture_key k ON k.capture_id = c.capture_id
      WHERE c.capture_id = ?
    `).get(captureId);
    if (!row) return null;
    const dataKey = unseal(masterKey, row.wrapped_key, `key:${captureId}`);
    return unseal(dataKey, row.text_sealed, `text:${captureId}`).toString('utf8');
  }

  /** A capture's payload bytes, unsealed; null when it has none or they were erased. */
  function payloadBytes(captureId) {
    const row = db.prepare(`
      SELECT k.wrapped_key, b.sealed FROM capture_event e
      JOIN payload_blob b ON b.payload_hash = e.payload_hash
      JOIN capture_key k ON k.capture_id = e.capture_id
      WHERE e.capture_id = ?
    `).get(captureId);
    if (!row) return null;
    const dataKey = unseal(masterKey, row.wrapped_key, `key:${captureId}`);
    return unseal(dataKey, row.sealed, `payload:${captureId}`);
  }

  function registerProjection({ name, kind }) {
    db.prepare(`
      INSERT INTO projection (projection_name, kind, created_at) VALUES (?, ?, ?)
      ON CONFLICT (projection_name) DO NOTHING
    `).run(name, kind, now());
  }

  /**
   * Record that a projection holds something derived from a capture, so
   * revocation knows what to prune (R3). With `output`, the store keeps what
   * was derived, sealed under the capture's own data key (ADR 0007): revoking
   * the capture deletes it and destroys the key that sealed it.
   */
  function addProjectionEntry(entry) {
    immediate(() => addProjectionEntryLocked(entry));
  }

  /**
   * Under the write lock, so a revocation can't land between the check and
   * the insert and leave an entry behind for a capture it pruned.
   */
  function addProjectionEntryLocked({ projection, captureId, entryRef, output }) {
    if (isRevoked(captureId)) throw new RevokedError('no projection entry for a capture that is revoked or unknown');
    let kind = null;
    let sealed = null;
    if (output) {
      const row = db.prepare('SELECT wrapped_key FROM capture_key WHERE capture_id = ?').get(captureId);
      if (!row) throw new RevokedError('no output for a capture that is revoked or unknown');
      const dataKey = unseal(masterKey, row.wrapped_key, `key:${captureId}`);
      kind = output.kind;
      sealed = seal(dataKey, Buffer.from(JSON.stringify(output.value)), `projection:${projection}:${captureId}:${entryRef}`);
    }
    // Recording again that an entry exists changes nothing, so an index that
    // failed after recording can retry. An entry with an output is kept once.
    // An output takes the next number in the store's sequence (migration 010),
    // so a reader that follows outputs finds one written after its capture.
    db.prepare(`
      INSERT INTO projection_entry (projection_name, capture_id, entry_ref, created_at, output_kind, output_sealed, output_sequence)
      VALUES (?, ?, ?, ?, ?, ?, ?) ${output ? '' : 'ON CONFLICT (projection_name, capture_id, entry_ref) DO NOTHING'}
    `).run(projection, captureId, entryRef, now(), kind, sealed, output ? nextSequence() : null);
  }

  /** What a projection keeps for a capture, unsealed: [{entryRef, kind, value}]. */
  function projectionOutputs({ projection, captureId }) {
    const row = db.prepare('SELECT wrapped_key FROM capture_key WHERE capture_id = ?').get(captureId);
    if (!row) return [];
    const dataKey = unseal(masterKey, row.wrapped_key, `key:${captureId}`);
    return db.prepare(`
      SELECT entry_ref, output_kind, output_sealed FROM projection_entry
      WHERE projection_name = ? AND capture_id = ? AND output_sealed IS NOT NULL ORDER BY entry_ref
    `).all(projection, captureId).map((r) => ({
      entryRef: r.entry_ref,
      kind: r.output_kind,
      value: JSON.parse(unseal(dataKey, r.output_sealed, `projection:${projection}:${captureId}:${r.entry_ref}`).toString('utf8')),
    }));
  }

  /**
   * A projector's outputs for one capture and its watermark, in one
   * transaction: a capture is projected whole or not at all, and the
   * watermark never passes a capture whose outputs weren't all kept.
   */
  function recordProjection({ projection, captureId, outputs, consumer, sequence }) {
    immediate(() => {
      for (const o of outputs) {
        addProjectionEntryLocked({ projection, captureId, entryRef: o.ref, output: { kind: o.kind, value: o.value } });
      }
      setWatermark(consumer, sequence);
    });
  }

  /** A consumer's position in the event stream (R4): the last sequence it processed. */
  function watermark(consumer) {
    return db.prepare('SELECT last_sequence FROM replay_watermark WHERE consumer = ?').get(consumer)?.last_sequence ?? 0;
  }

  function setWatermark(consumer, sequence) {
    db.prepare(`
      INSERT INTO replay_watermark (consumer, last_sequence, updated_at) VALUES (?, ?, ?)
      ON CONFLICT (consumer) DO UPDATE SET last_sequence = excluded.last_sequence, updated_at = excluded.updated_at
    `).run(consumer, sequence, now());
  }

  // ------------------------------------------------------------ revocation

  /**
   * Fills temp.revoking with what a revocation reaches: the captures its scope
   * names and everything derived from them (R10), less what's already revoked
   * (erased when it was). The chain is followed through revoked captures too:
   * a store from before R13 can hold a readable capture derived from one. All
   * in SQL, so a scope of any size
   * (retention's, from the epoch, takes in every capture ever revoked) never
   * becomes a list of parameters. Kept in memory (temp_store), never in a file.
   */
  function resolveScope({ scopeKind, scopeValue }) {
    const [where, params] = {
      capture: () => ['capture_id = ?', [scopeValue]],
      source: () => ['(source = ? OR source_app = ?)', [scopeValue, scopeValue]],
      privacy_level: () => ['privacy_level = ?', [scopeValue]],
      time_range: () => ['captured_at >= ? AND captured_at <= ?', canonicalRange(scopeValue).split('/')],
    }[scopeKind]?.() ?? [];
    if (!where) throw new Error(`unknown scope kind: ${scopeKind}`);

    db.exec('CREATE TEMP TABLE IF NOT EXISTS revoking (capture_id TEXT PRIMARY KEY, cascaded INTEGER NOT NULL)');
    db.exec('DELETE FROM temp.revoking');
    // Each capture is reached once, by its id alone: a chain that loops back
    // on itself (a capture recorded as derived from itself) ends.
    db.prepare(`
      WITH RECURSIVE reached (capture_id) AS (
        SELECT capture_id FROM capture_event WHERE ${where}
        UNION
        SELECT e.capture_id FROM capture_event e JOIN reached r ON e.derived_from = r.capture_id
      )
      INSERT INTO temp.revoking (capture_id, cascaded)
      SELECT capture_id, capture_id NOT IN (SELECT capture_id FROM capture_event WHERE ${where}) FROM reached
      WHERE capture_id NOT IN (SELECT capture_id FROM revoked_capture)
    `).run(...params, ...params);
  }

  /**
   * Revoke captures. Materialises the revoked set, cascades to derived
   * artifacts (R10), prunes every projection that referenced them, and records
   * a per-projection receipt proving the prune happened (R3). Then erases the
   * content itself: keys, sealed text and sealed bytes, with a receipt (R11).
   */
  function revoke({ scopeKind, scopeValue, reason }) {
    const revocationId = `rev_${randomUUID()}`;
    const revokedAt = now();
    // Kept in canonical form, so later appends compare against it as text (refuseForgotten).
    const value = scopeKind === 'time_range' ? canonicalRange(scopeValue) : scopeValue;

    // The scope is resolved under the write lock, in the transaction that
    // records it: a capture another writer appends meanwhile is either in the
    // set, or appended after this commits and refused (refuseForgotten).
    const revokedIds = immediate(() => {
      resolveScope({ scopeKind, scopeValue: value });
      db.prepare(`
        INSERT INTO revocation (revocation_id, sequence, revoked_at, scope_kind, scope_value, reason)
        VALUES (?, ?, ?, ?, ?, ?)
      `).run(revocationId, nextSequence(), revokedAt, scopeKind, value, reason ?? null);

      db.prepare(`
        INSERT INTO revoked_capture (capture_id, revocation_id, revoked_at, cascaded)
        SELECT capture_id, ?, ?, cascaded FROM temp.revoking
      `).run(revocationId, revokedAt);

      // Propagate into every projection. This is the property no competitor
      // has, so it gets a receipt rather than a best effort.
      const projections = db.prepare('SELECT projection_name FROM projection').all();
      for (const { projection_name: projectionName } of projections) {
        const removed = Number(db.prepare(`
          DELETE FROM projection_entry
          WHERE projection_name = ? AND capture_id IN (SELECT capture_id FROM temp.revoking)
        `).run(projectionName).changes);
        db.prepare(`
          INSERT INTO projection_revocation
            (projection_name, revocation_id, applied_at, entries_removed)
          VALUES (?, ?, ?, ?)
        `).run(projectionName, revocationId, now(), removed);
      }

      // Erase the content. The key goes in the same transaction as the record
      // of the revocation, so there is no moment at which a revocation is
      // recorded and its content still readable (R11).
      const payloads = Number(db.prepare(`
        DELETE FROM payload_blob WHERE payload_hash IN (
          SELECT payload_hash FROM capture_event
          WHERE capture_id IN (SELECT capture_id FROM temp.revoking) AND payload_hash IS NOT NULL
        )
      `).run().changes);
      const contents = Number(db.prepare('DELETE FROM capture_content WHERE capture_id IN (SELECT capture_id FROM temp.revoking)')
        .run().changes);
      const keys = Number(db.prepare('DELETE FROM capture_key WHERE capture_id IN (SELECT capture_id FROM temp.revoking)')
        .run().changes);
      db.prepare(`
        INSERT INTO erasure_receipt
          (revocation_id, applied_at, keys_destroyed, contents_erased, payloads_erased)
        VALUES (?, ?, ?, ?, ?)
      `).run(revocationId, now(), keys, contents, payloads);
      return db.prepare(`
        SELECT r.capture_id FROM temp.revoking r JOIN capture_event e USING (capture_id) ORDER BY r.cascaded, e.sequence
      `).all().map((r) => r.capture_id);
    });

    // The revocation is committed: from here on, nothing that fails can make
    // it not have happened. A failure finishing the erasure leaves it pending
    // (its receipt has no completed_at), to be finished by the next writer,
    // and says so, rather than reading as nothing forgotten.
    let erasedOnDisk = false;
    let erasureError;
    try {
      erasedOnDisk = truncateLog() && !pendingThrough(revocationId);
    } catch (err) {
      erasureError = err.message;
    }
    return { revocationId, revokedCaptureIds: revokedIds, erasedOnDisk, ...(erasureError && { erasureError }) };
  }

  /** Whether this revocation's erasure is still waiting to be recorded done. */
  const pendingThrough = (revocationId) =>
    db.prepare('SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?').get(revocationId)?.completed_at == null;

  /** Whether an erasure is still waiting for the log to be truncated, by this process or another. */
  const erasurePending = () =>
    db.prepare('SELECT 1 FROM erasure_receipt WHERE completed_at IS NULL LIMIT 1').get() !== undefined;

  /**
   * The deleted pages, zeroed by secure_delete, are still preceded in the
   * write-ahead log by the frames that wrote the content. Fold the log into the
   * database and truncate it, so those frames are gone from disk too.
   *
   * A reader in another process holding a snapshot blocks the truncation, and
   * SQLite says so only in the result row (busy = 1), not as an error. Retried
   * for about a second; true once the log is truncated. Until it is, the
   * erasure is not reported done, its receipt has no completed_at, and any
   * writer finishes it later (finishErasure, or opening the store).
   */
  function truncateLog(attempts = 20) {
    // Only the erasures already committed when the checkpoint starts are
    // proven by it. One another writer commits after, while a reader holds the
    // log again, is not, and stays pending.
    const through = db.prepare('SELECT COALESCE(MAX(sequence), 0) AS s FROM revocation').get().s;
    let truncated = false;
    // Retried on its own short schedule, so SQLite's busy wait is off while it
    // tries: with it on, each attempt would wait out the whole busy timeout.
    db.exec('PRAGMA busy_timeout = 0');
    try {
      for (let i = 0; i < attempts && !truncated; i++) {
        truncated = db.prepare('PRAGMA wal_checkpoint(TRUNCATE)').get().busy === 0;
        if (!truncated && i < attempts - 1) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
      }
    } finally {
      db.exec('PRAGMA busy_timeout = 5000');
    }
    if (truncated) {
      onTruncated?.();
      stampErasures(through);
    }
    return truncated;
  }

  /**
   * Every erasure pending through revocation `through` is done: the log
   * holding its frames was just truncated. Recorded in the store, so it
   * survives this process. If the stamp can't be written now (another writer
   * held the lock throughout the busy timeout), the receipts stay pending,
   * which is never wrong, and the next truncation stamps them.
   */
  function stampErasures(through) {
    try {
      db.prepare(`
        UPDATE erasure_receipt SET completed_at = ?
        WHERE completed_at IS NULL AND revocation_id IN (SELECT revocation_id FROM revocation WHERE sequence <= ?)
      `).run(now(), through);
    } catch (err) {
      if ((err.errcode & 0xff) !== 5) throw err; // SQLITE_BUSY
    }
  }

  /** Finishes an erasure a reader held up. True once nothing revoked is left in the log. */
  function finishErasure() {
    if (!erasurePending()) return true;
    truncateLog(1);
    return !erasurePending();
  }

  // A writer opening the store finishes what an earlier one couldn't: a
  // command-line revocation, say, that exited while a reader held the log.
  if (erasurePending()) truncateLog(1);

  /**
   * Retention is a scheduled revocation (ADR 0003), not a delete: everything
   * captured more than `days` ago is revoked with reason 'retention', and gets
   * the same receipts as any other revocation. Returns null when nothing is
   * old enough, so an hourly schedule does not fill the log with empty ones.
   */
  function retain({ days, now: at = new Date() }) {
    if (!(days > 0)) throw new Error('retention days must be positive');
    const cutoff = new Date(at.getTime() - days * 86_400_000).toISOString();
    const { n } = db.prepare(`
      SELECT COUNT(*) AS n FROM capture_event
      WHERE captured_at <= ? AND capture_id NOT IN (SELECT capture_id FROM revoked_capture)
    `).get(cutoff);
    if (n === 0) return null;
    return revoke({ scopeKind: 'time_range', scopeValue: `${EPOCH}/${cutoff}`, reason: 'retention' });
  }

  // ----------------------------------------------------------------- reads

  function issueGrant(grant) {
    const grantId = grant.grantId ?? `grn_${randomUUID()}`;
    if (!grant.expiresAt) {
      throw new Error('a grant with no expiry is not issuable (ADR 0001 §4.1)');
    }
    db.prepare(`
      INSERT INTO grant_record (
        grant_id, client_id, issued_at, expires_at, domains, time_from, time_to,
        privacy_levels, capture_types, sources, max_rows_per_query, revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
    `).run(
      grantId,
      grant.clientId,
      now(),
      canonicalTime(grant.expiresAt, 'expiresAt'),
      JSON.stringify(grant.domains ?? ['*']),
      grant.timeFrom == null ? null : canonicalTime(grant.timeFrom, 'timeFrom'),
      grant.timeTo == null ? null : canonicalTime(grant.timeTo, 'timeTo'),
      JSON.stringify(grant.privacyLevels ?? ['standard']),
      JSON.stringify(grant.captureTypes ?? ['*']),
      JSON.stringify(grant.sources ?? ['*']),
      grant.maxRowsPerQuery ?? 100,
    );
    return grantId;
  }

  function revokeGrant(grantId) {
    db.prepare('UPDATE grant_record SET revoked_at = ? WHERE grant_id = ?').run(now(), grantId);
  }

  /**
   * Chained to the last record, under the write lock the read holds from its
   * start (BEGIN IMMEDIATE), so another process can't take the same last
   * record and fork the chain (migration 007 refuses a fork besides).
   */
  function appendEgressLocked(record) {
    const prev = db
      .prepare('SELECT record_hash FROM egress_record ORDER BY egress_id DESC LIMIT 1')
      .get();
    const prevHash = prev?.record_hash ?? GENESIS_HASH;
    const body = JSON.stringify({ ...record, prevHash });
    const recordHash = sha256(body);
    db.prepare(`
      INSERT INTO egress_record (
        served_at, client_id, grant_id, tool, query_fingerprint, capture_ids,
        privacy_levels_served, row_count, byte_count, prev_hash, record_hash
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      record.servedAt,
      record.clientId,
      record.grantId,
      record.tool,
      record.queryFingerprint,
      JSON.stringify(record.captureIds),
      JSON.stringify(record.privacyLevelsServed),
      record.rowCount,
      record.byteCount,
      prevHash,
      recordHash,
    );
  }

  const grantRecord = (grantId) => db.prepare('SELECT * FROM grant_record WHERE grant_id = ?').get(grantId);

  /**
   * The only read path. Enforcement lives here, below any tool handler, so a
   * handler that forgets to filter still cannot over-serve (ADR 0001 §4.1).
   * A reader can be kept and reused: each read looks its grant up afresh, so
   * a grant revoked since the reader was made is refused.
   */
  function createReader(grantId) {
    if (!grantRecord(grantId)) throw new AuthorizationError('no grant: default deny');
    return {
      read: (request) => read(grantId, request),
      readCaptures: (request) => readCaptures(grantId, request),
      readOutputs: (request) => readOutputs(grantId, request),
    };
  }

  /** The grant a read is made under, as it is now: refused when it's missing, revoked or expired. */
  function authorizedGrant(grantId) {
    const grant = grantRecord(grantId);
    if (!grant) throw new AuthorizationError('no grant: default deny');
    if (grant.revoked_at) throw new AuthorizationError('grant revoked');
    if (grant.expires_at <= now()) throw new AuthorizationError('grant expired');
    return grant;
  }

  // Checked before it's compared: Math.min with anything but a number is NaN,
  // which no count reaches, and the grant's cap would be lost.
  function checkLimit(limit) {
    if (limit != null && !(Number.isInteger(limit) && limit >= 0)) throw new RangeError('limit must be a whole number, 0 or more');
  }

  /**
   * Every read has two parts. What the grant admits is chosen and unsealed
   * under a read snapshot, which never holds the write lock, so a search
   * through a long history doesn't keep the daemon, or a Forget, waiting.
   * Then it's served only once the grant is checked again and the serving
   * recorded, in one transaction under the write lock: a grant revoked
   * meanwhile serves nothing, a capture revoked meanwhile isn't served (R2),
   * and every row served is in the egress log (ADR 0001).
   */
  function twoPhase(grantId, choose, { tool, query, contains }) {
    db.exec('BEGIN');
    let rows;
    try {
      rows = choose(authorizedGrant(grantId));
      db.exec('COMMIT');
    } catch (err) {
      db.exec('ROLLBACK');
      throw err;
    }
    return immediate(() => {
      const grant = authorizedGrant(grantId);
      const served = rows.filter((r) => !isRevoked(r.envelope.presence_capture_untrusted.provenance.capture_id));
      const envelopes = served.map((r) => r.envelope);
      appendEgressLocked({
        servedAt: now(),
        clientId: grant.client_id,
        grantId: grant.grant_id,
        tool,
        queryFingerprint: sha256(`${tool}\u0000${query}\u0000${contains ?? ''}`),
        captureIds: served.map((r) => r.envelope.presence_capture_untrusted.provenance.capture_id),
        privacyLevelsServed: [...new Set(served.map((r) => r.envelope.presence_capture_untrusted.provenance.privacy_level))],
        rowCount: served.length,
        byteCount: Buffer.byteLength(JSON.stringify(envelopes)),
      });
      return envelopes;
    });
  }

  /** What the grant admits, in sequence order, with its text, up to its cap. */
  function read(grantId, { tool, query = '', contains = null, limit = null, afterSequence = null }) {
    checkLimit(limit);
    return twoPhase(grantId, (grant) => {
      const { clauses, params } = admits(grant);
      if (afterSequence != null) { clauses.push('e.sequence > ?'); params.push(afterSequence); }
      // Content is sealed, so `contains` is matched after unsealing, and only
      // rows the grant already admits are ever unsealed. Case-insensitive, as
      // the LIKE it replaces was for ASCII.
      const cap = Math.min(limit ?? grant.max_rows_per_query, grant.max_rows_per_query);
      const needle = contains?.toLowerCase();
      const rows = [];
      const candidates = db.prepare(`SELECT e.* FROM capture_event e WHERE ${clauses.join(' AND ')} ORDER BY e.sequence`).iterate(...params);
      for (const row of candidates) {
        if (rows.length >= cap) break;
        const text = contentText(row.capture_id);
        if (needle && !text?.toLowerCase().includes(needle)) continue;
        rows.push({ envelope: envelopeOf(row, text) });
      }
      return rows;
    }, { tool, query, contains });
  }

  /**
   * The captures named, in the order named, through the grant: how a ranked
   * result (a search's) is served. What the grant doesn't admit, or is
   * revoked, is left out, a capture named twice is served once, and no more
   * than the grant's cap is served.
   */
  function readCaptures(grantId, { tool, query = '', captureIds }) {
    if (!Array.isArray(captureIds) || captureIds.some((id) => typeof id !== 'string')) {
      throw new RangeError('captureIds must be a list of capture ids');
    }
    return twoPhase(grantId, (grant) => {
      const { clauses, params } = admits(grant);
      const one = db.prepare(`SELECT e.* FROM capture_event e WHERE ${[...clauses, 'e.capture_id = ?'].join(' AND ')}`);
      const rows = [];
      for (const id of new Set(captureIds)) {
        if (rows.length >= grant.max_rows_per_query) break;
        const row = one.get(...params, id);
        if (row) rows.push({ envelope: envelopeOf(row, contentText(id)) });
      }
      return rows;
    }, { tool, query, contains: null });
  }

  /**
   * Projection outputs (an embedding, a summary) of the captures the grant
   * admits, in the order they were written (output_sequence, migration 010),
   * after `afterOutputSequence`, up to the grant's cap. Each is enveloped with
   * its capture's provenance, and its content is the output's JSON as text.
   */
  function readOutputs(grantId, { tool, kind = null, afterOutputSequence = 0, limit = null }) {
    checkLimit(limit);
    if (!Number.isInteger(afterOutputSequence)) throw new RangeError('afterOutputSequence must be a whole number');
    return twoPhase(grantId, (grant) => {
      const { clauses, params } = admits(grant);
      clauses.push('p.output_sealed IS NOT NULL', 'p.output_sequence > ?');
      params.push(afterOutputSequence);
      if (kind != null) { clauses.push('p.output_kind = ?'); params.push(kind); }
      const cap = Math.min(limit ?? grant.max_rows_per_query, grant.max_rows_per_query);
      const rows = [];
      const candidates = db.prepare(`
        SELECT e.*, p.projection_name, p.entry_ref, p.output_kind, p.output_sealed, p.output_sequence, k.wrapped_key
        FROM projection_entry p
        JOIN capture_event e ON e.capture_id = p.capture_id
        JOIN capture_key k ON k.capture_id = p.capture_id
        WHERE ${clauses.join(' AND ')} ORDER BY p.output_sequence
      `).iterate(...params);
      for (const row of candidates) {
        if (rows.length >= cap) break;
        const dataKey = unseal(masterKey, row.wrapped_key, `key:${row.capture_id}`);
        const text = unseal(dataKey, row.output_sealed, `projection:${row.projection_name}:${row.capture_id}:${row.entry_ref}`).toString('utf8');
        const envelope = envelopeOf(row, text, {
          projection: row.projection_name,
          entry_ref: row.entry_ref,
          output_kind: row.output_kind,
          output_sequence: row.output_sequence,
        });
        rows.push({ envelope });
      }
      return rows;
    }, { tool, query: kind ?? '', contains: null });
  }

  /** The SQL a grant admits captures by: privacy levels, types, domains, sources and time. */
  function admits(grant) {
    const levels = JSON.parse(grant.privacy_levels);
    const types = JSON.parse(grant.capture_types);
    const domains = JSON.parse(grant.domains);
    const sources = JSON.parse(grant.sources);

    // sacred_mode can never appear here: the column CHECK in 004 rejects a
    // grant that names it, so there is no value to filter against.
    const clauses = ['e.capture_id NOT IN (SELECT capture_id FROM revoked_capture)'];
    const params = [];

    clauses.push(`e.privacy_level IN (${levels.map(() => '?').join(',')})`);
    params.push(...levels);

    if (!types.includes('*')) {
      clauses.push(`e.capture_type IN (${types.map(() => '?').join(',')})`);
      params.push(...types);
    }
    if (!domains.includes('*')) {
      clauses.push(`e.classification IN (${domains.map(() => '?').join(',')})`);
      params.push(...domains);
    }
    if (!sources.includes('*')) {
      clauses.push(`e.source IN (${sources.map(() => '?').join(',')})`);
      params.push(...sources);
    }
    if (grant.time_from) { clauses.push('e.captured_at >= ?'); params.push(grant.time_from); }
    if (grant.time_to)   { clauses.push('e.captured_at <= ?'); params.push(grant.time_to); }
    return { clauses, params };
  }

  /**
   * Every payload crosses the boundary wrapped (ADR 0001 §4.3). Provenance
   * comes from capture metadata, never from the content; an output adds where
   * it came from after the capture's own.
   */
  function envelopeOf(row, content, output = {}) {
    return {
      presence_capture_untrusted: {
        envelope_version: ENVELOPE_VERSION,
        provenance: {
          capture_id: row.capture_id,
          sequence: row.sequence,
          captured_at: row.captured_at,
          source_app: row.source_app,
          source_url: row.source_url,
          capture_type: row.capture_type,
          privacy_level: row.privacy_level,
          extraction: row.extraction,
          ...output,
        },
        content,
      },
    };
  }

  // ---------------------------------------------------------------- replay

  /**
   * Re-derive a projection from the event stream and hash the result. Two
   * replays over the same stream must produce the same hash (R4).
   */
  function replay({ consumer, derive }) {
    // Each event is handed to derive with its text unsealed as content_text,
    // the shape a consumer saw before content left the log.
    const events = db
      .prepare(`
        SELECT * FROM capture_event
        WHERE capture_id NOT IN (SELECT capture_id FROM revoked_capture)
        ORDER BY sequence
      `)
      .all()
      .map((e) => ({ ...e, content_text: contentText(e.capture_id) }));

    const state = events.map((e) => derive(e)).filter((v) => v !== undefined);
    const stateHash = sha256(JSON.stringify(state));
    const through = events.length > 0 ? events[events.length - 1].sequence : 0;

    db.prepare(`
      INSERT INTO replay_receipt (consumer, through_sequence, state_hash, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT (consumer, through_sequence) DO NOTHING
    `).run(consumer, through, stateHash, now());

    db.prepare(`
      INSERT INTO replay_watermark (consumer, last_sequence, updated_at) VALUES (?, ?, ?)
      ON CONFLICT (consumer) DO UPDATE SET last_sequence = excluded.last_sequence,
                                           updated_at    = excluded.updated_at
    `).run(consumer, through, now());

    return { stateHash, throughSequence: through, state };
  }

  /** Recompute the egress hash chain. Any tampered record breaks it. */
  function verifyEgressChain() {
    const rows = db.prepare('SELECT * FROM egress_record ORDER BY egress_id').all();
    let prevHash = GENESIS_HASH;
    for (const r of rows) {
      const body = JSON.stringify({
        servedAt: r.served_at,
        clientId: r.client_id,
        grantId: r.grant_id,
        tool: r.tool,
        queryFingerprint: r.query_fingerprint,
        captureIds: JSON.parse(r.capture_ids),
        privacyLevelsServed: JSON.parse(r.privacy_levels_served),
        rowCount: r.row_count,
        byteCount: r.byte_count,
        prevHash,
      });
      if (r.prev_hash !== prevHash) return { ok: false, brokenAt: r.egress_id, reason: 'prev_hash' };
      if (sha256(body) !== r.record_hash) {
        return { ok: false, brokenAt: r.egress_id, reason: 'record_hash' };
      }
      prevHash = r.record_hash;
    }
    return { ok: true, records: rows.length };
  }

  return {
    db,
    appendCapture, appendAll, contentText, payloadBytes, dedupeKeyFor, registerProjection, addProjectionEntry,
    projectionOutputs, recordProjection, watermark, setWatermark,
    revoke, retain, finishErasure, get erasurePending() { return erasurePending(); }, issueGrant, revokeGrant, createReader, replay, verifyEgressChain,
    close: () => db.close(),
  };
}

export { ENVELOPE_VERSION };
