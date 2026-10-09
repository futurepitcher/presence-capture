import { createHash, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { migrate } from './migrate.js';

const ENVELOPE_VERSION = '1';
const GENESIS_HASH = '0'.repeat(64);

const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const now = () => new Date().toISOString();

/** Raised when a read is attempted without sufficient authority. */
export class AuthorizationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AuthorizationError';
  }
}

/**
 * Open a conformant capture store.
 *
 * @param {string} [path] file path, or ':memory:' for an ephemeral store
 */
export function openStore(path = ':memory:') {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys = ON');
  migrate(db);

  const nextSequence = () => {
    const { seq } = db
      .prepare(`
        SELECT COALESCE(MAX(s), 0) + 1 AS seq FROM (
          SELECT MAX(sequence) AS s FROM capture_event
          UNION ALL
          SELECT MAX(sequence) AS s FROM revocation
        )
      `)
      .get();
    return seq;
  };

  // ---------------------------------------------------------------- writes

  function putPayload({ bytes, mediaType, storageUri }) {
    const payloadHash = sha256(bytes);
    db.prepare(`
      INSERT INTO capture_payload (payload_hash, byte_count, media_type, storage_uri, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (payload_hash) DO NOTHING
    `).run(payloadHash, Buffer.byteLength(bytes), mediaType, storageUri, now());
    return payloadHash;
  }

  function appendCapture(event) {
    const captureId = event.captureId ?? `cap_${randomUUID()}`;
    db.prepare(`
      INSERT INTO capture_event (
        capture_id, sequence, captured_at, capture_type, source, source_app,
        source_url, privacy_level, classification, payload_hash, content_text,
        extraction, derived_from, dedupe_key
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      captureId,
      nextSequence(),
      event.capturedAt ?? now(),
      event.captureType,
      event.source,
      event.sourceApp ?? null,
      event.sourceUrl ?? null,
      event.privacyLevel,
      event.classification ?? null,
      event.payloadHash ?? null,
      event.contentText ?? null,
      event.extraction ?? null,
      event.derivedFrom ?? null,
      event.dedupeKey ?? null,
    );
    return captureId;
  }

  function registerProjection({ name, kind }) {
    db.prepare(`
      INSERT INTO projection (projection_name, kind, created_at) VALUES (?, ?, ?)
      ON CONFLICT (projection_name) DO NOTHING
    `).run(name, kind, now());
  }

  function addProjectionEntry({ projection, captureId, entryRef }) {
    db.prepare(`
      INSERT INTO projection_entry (projection_name, capture_id, entry_ref, created_at)
      VALUES (?, ?, ?, ?)
    `).run(projection, captureId, entryRef, now());
  }

  // ------------------------------------------------------------ revocation

  /** Captures matching a revocation scope, plus everything derived from them (R10). */
  function resolveScope({ scopeKind, scopeValue }) {
    const direct = {
      capture: () =>
        db.prepare('SELECT capture_id FROM capture_event WHERE capture_id = ?').all(scopeValue),
      source: () =>
        db.prepare('SELECT capture_id FROM capture_event WHERE source = ? OR source_app = ?')
          .all(scopeValue, scopeValue),
      privacy_level: () =>
        db.prepare('SELECT capture_id FROM capture_event WHERE privacy_level = ?').all(scopeValue),
      time_range: () => {
        const [from, to] = scopeValue.split('/');
        return db
          .prepare('SELECT capture_id FROM capture_event WHERE captured_at >= ? AND captured_at <= ?')
          .all(from, to);
      },
    }[scopeKind];

    if (!direct) throw new Error(`unknown scope kind: ${scopeKind}`);

    const seeds = direct().map((r) => r.capture_id);
    const all = new Map(seeds.map((id) => [id, false])); // id -> cascaded?
    let frontier = seeds;

    while (frontier.length > 0) {
      const placeholders = frontier.map(() => '?').join(',');
      const children = db
        .prepare(`SELECT capture_id FROM capture_event WHERE derived_from IN (${placeholders})`)
        .all(...frontier)
        .map((r) => r.capture_id)
        .filter((id) => !all.has(id));
      for (const id of children) all.set(id, true);
      frontier = children;
    }

    return all;
  }

  /**
   * Revoke captures. Materialises the revoked set, cascades to derived
   * artifacts (R10), prunes every projection that referenced them, and records
   * a per-projection receipt proving the prune happened (R3).
   */
  function revoke({ scopeKind, scopeValue, reason }) {
    const revocationId = `rev_${randomUUID()}`;
    const revokedAt = now();
    const affected = resolveScope({ scopeKind, scopeValue });

    db.exec('BEGIN');
    try {
      db.prepare(`
        INSERT INTO revocation (revocation_id, sequence, revoked_at, scope_kind, scope_value, reason)
        VALUES (?, ?, ?, ?, ?, ?)
      `).run(revocationId, nextSequence(), revokedAt, scopeKind, scopeValue, reason ?? null);

      const markRevoked = db.prepare(`
        INSERT INTO revoked_capture (capture_id, revocation_id, revoked_at, cascaded)
        VALUES (?, ?, ?, ?)
        ON CONFLICT (capture_id) DO NOTHING
      `);
      for (const [captureId, cascaded] of affected) {
        markRevoked.run(captureId, revocationId, revokedAt, cascaded ? 1 : 0);
      }

      // Propagate into every projection. This is the property no competitor
      // has, so it gets a receipt rather than a best effort.
      const projections = db.prepare('SELECT projection_name FROM projection').all();
      const ids = [...affected.keys()];
      for (const { projection_name: projectionName } of projections) {
        let removed = 0;
        if (ids.length > 0) {
          const placeholders = ids.map(() => '?').join(',');
          const result = db
            .prepare(`
              DELETE FROM projection_entry
              WHERE projection_name = ? AND capture_id IN (${placeholders})
            `)
            .run(projectionName, ...ids);
          removed = Number(result.changes);
        }
        db.prepare(`
          INSERT INTO projection_revocation
            (projection_name, revocation_id, applied_at, entries_removed)
          VALUES (?, ?, ?, ?)
        `).run(projectionName, revocationId, now(), removed);
      }

      db.exec('COMMIT');
    } catch (err) {
      db.exec('ROLLBACK');
      throw err;
    }

    return { revocationId, revokedCaptureIds: [...affected.keys()] };
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
      grant.expiresAt,
      JSON.stringify(grant.domains ?? ['*']),
      grant.timeFrom ?? null,
      grant.timeTo ?? null,
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

  function appendEgress(record) {
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

  /**
   * The only read path. Enforcement lives here, below any tool handler, so a
   * handler that forgets to filter still cannot over-serve (ADR 0001 §4.1).
   */
  function createReader(grantId) {
    const grant = db.prepare('SELECT * FROM grant_record WHERE grant_id = ?').get(grantId);
    if (!grant) throw new AuthorizationError('no grant: default deny');

    return {
      read({ tool, query = '', contains = null, limit = null }) {
        if (grant.revoked_at) throw new AuthorizationError('grant revoked');
        if (grant.expires_at <= now()) throw new AuthorizationError('grant expired');

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
        if (contains)        { clauses.push('e.content_text LIKE ?'); params.push(`%${contains}%`); }

        const cap = Math.min(limit ?? grant.max_rows_per_query, grant.max_rows_per_query);
        const rows = db
          .prepare(`
            SELECT e.* FROM capture_event e
            WHERE ${clauses.join(' AND ')}
            ORDER BY e.sequence
            LIMIT ?
          `)
          .all(...params, cap);

        // Every payload crosses the boundary wrapped (ADR 0001 §4.3).
        // provenance comes from capture metadata, never from the content.
        const envelopes = rows.map((r) => ({
          presence_capture_untrusted: {
            envelope_version: ENVELOPE_VERSION,
            provenance: {
              capture_id: r.capture_id,
              captured_at: r.captured_at,
              source_app: r.source_app,
              source_url: r.source_url,
              capture_type: r.capture_type,
              privacy_level: r.privacy_level,
              extraction: r.extraction,
            },
            content: r.content_text,
          },
        }));

        appendEgress({
          servedAt: now(),
          clientId: grant.client_id,
          grantId: grant.grant_id,
          tool,
          queryFingerprint: sha256(`${tool}\u0000${query}\u0000${contains ?? ''}`),
          captureIds: rows.map((r) => r.capture_id),
          privacyLevelsServed: [...new Set(rows.map((r) => r.privacy_level))],
          rowCount: rows.length,
          byteCount: Buffer.byteLength(JSON.stringify(envelopes)),
        });

        return envelopes;
      },
    };
  }

  // ---------------------------------------------------------------- replay

  /**
   * Re-derive a projection from the event stream and hash the result. Two
   * replays over the same stream must produce the same hash (R4).
   */
  function replay({ consumer, derive }) {
    const events = db
      .prepare(`
        SELECT * FROM capture_event
        WHERE capture_id NOT IN (SELECT capture_id FROM revoked_capture)
        ORDER BY sequence
      `)
      .all();

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
    putPayload, appendCapture, registerProjection, addProjectionEntry,
    revoke, issueGrant, revokeGrant, createReader, replay, verifyEgressChain,
    close: () => db.close(),
  };
}

export { ENVELOPE_VERSION };
