/**
 * What a reader recalls from (ADR 0008): every capture its grant admits,
 * unsealed into memory and nowhere else. Keyword search is SQLite FTS5 in
 * `:memory:`; sessions are computed from activity when asked for.
 *
 * It's built by reading through the grant, so the store enforces the grant and
 * records every row the reader unsealed in the egress log (tool `index`). It's
 * kept current on each call: captures after the last one read, and revocations
 * after the last one seen, which are evicted. Whatever it ranks is then served
 * by id through the grant again, so nothing it holds is ever served without
 * the store's say: a capture revoked or a grant withdrawn since serves nothing.
 */

import { DatabaseSync } from 'node:sqlite';
import { sessionsOf } from '@presence-capture/schema';

const HOUR = 3_600_000;

/** Raised when what an answer was computed from kept changing while it was served: ask again. */
export class ChangedError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ChangedError';
  }
}

/** A time argument, as the store writes times; RangeError for anything else. */
function timeArg(value, name, fallback) {
  if (value == null) return fallback;
  const date = new Date(value);
  if (typeof value !== 'string' || Number.isNaN(date.getTime())) throw new RangeError(`${name} must be an ISO 8601 time`);
  return date.toISOString();
}

function limitArg(value, fallback) {
  if (value == null) return fallback;
  if (!Number.isInteger(value) || value < 1) throw new RangeError('limit must be a whole number, 1 or more');
  return value;
}

/**
 * @param {{store: object, grantId: string}} options  an open store and the
 *   grant this reader recalls under
 */
/**
 * An SQLite database in memory and nowhere else: its temporary storage too
 * (temp_store), so a large sort over unsealed content never spills to a file
 * outside the store's directory, where no revocation reaches it.
 */
export function openMemory() {
  const memory = new DatabaseSync(':memory:');
  memory.exec('PRAGMA temp_store = MEMORY');
  return memory;
}

export function createRecall({ store, grantId }) {
  const memory = openMemory();
  memory.exec(`
    CREATE TABLE doc (
      capture_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL, captured_at TEXT NOT NULL,
      capture_type TEXT NOT NULL, source_app TEXT, content TEXT
    );
    CREATE INDEX doc_time ON doc (captured_at);
    CREATE VIRTUAL TABLE words USING fts5(capture_id UNINDEXED, content);
  `);
  let afterSequence = 0;
  let afterRevocation = 0;

  const reader = () => store.createReader(grantId);

  /** New captures the grant admits, and revocations since the last look. */
  function refresh() {
    const latest = store.db.prepare('SELECT COALESCE(MAX(sequence), 0) AS s FROM capture_event').get().s;
    const insertDoc = memory.prepare(`
      INSERT INTO doc (capture_id, sequence, captured_at, capture_type, source_app, content) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (capture_id) DO NOTHING
    `);
    const insertWords = memory.prepare('INSERT INTO words (capture_id, content) VALUES (?, ?)');
    while (afterSequence < latest) {
      const page = reader().read({ tool: 'index', query: 'index', afterSequence });
      if (page.length === 0) break;
      for (const { presence_capture_untrusted: { provenance: p, content } } of page) {
        insertDoc.run(p.capture_id, p.sequence, p.captured_at, p.capture_type, p.source_app, content);
        if (content) insertWords.run(p.capture_id, content);
        afterSequence = Math.max(afterSequence, p.sequence);
      }
    }
    const revoked = store.db.prepare(`
      SELECT rc.capture_id, r.sequence FROM revoked_capture rc JOIN revocation r USING (revocation_id)
      WHERE r.sequence > ? ORDER BY r.sequence
    `).all(afterRevocation);
    for (const { capture_id: id, sequence } of revoked) {
      memory.prepare('DELETE FROM doc WHERE capture_id = ?').run(id);
      memory.prepare('DELETE FROM words WHERE capture_id = ?').run(id);
      afterRevocation = Math.max(afterRevocation, sequence);
    }
  }

  /**
   * Served by id, through the grant, in the order ranked. Every answer goes
   * through here, an empty one too, so every answer is authorized and
   * recorded.
   */
  const serve = (tool, query, captureIds) => reader().readCaptures({ tool, query, captureIds });

  /** Whether anything was revoked since memory was last brought up to date. */
  const revokedSinceRefresh = () =>
    store.db.prepare('SELECT 1 FROM revocation WHERE sequence > ? LIMIT 1').get(afterRevocation) !== undefined;
  const ids = (rows) => rows.map((r) => r.capture_id);

  function sessions() {
    const activity = memory.prepare("SELECT capture_id, captured_at, content FROM doc WHERE capture_type = 'activity' ORDER BY captured_at, sequence")
      .all()
      .map((r) => {
        let seen = {};
        try {
          seen = JSON.parse(r.content ?? '{}');
        } catch {
          seen = {};
        }
        return { id: r.capture_id, at: r.captured_at, state: seen.state ?? 'active', app: seen.app, window: seen.window, excluded: seen.excluded === true };
      });
    return sessionsOf(activity, { now: new Date().toISOString() });
  }

  const tools = {
    /** Keyword search, ranked by BM25: any word of the query. */
    search({ query, from, to, limit } = {}) {
      if (typeof query !== 'string') throw new RangeError('query must be text');
      const words = query.match(/[\p{L}\p{N}]+/gu) ?? [];
      if (words.length === 0) return serve('search', query, []);
      const match = words.map((w) => `"${w}"`).join(' OR ');
      const rows = memory.prepare(`
        SELECT words.capture_id FROM words JOIN doc ON doc.capture_id = words.capture_id
        WHERE words MATCH ? AND doc.captured_at >= ? AND doc.captured_at <= ?
        ORDER BY bm25(words), doc.sequence DESC LIMIT ?
      `).all(match, timeArg(from, 'from', '0000-01-01T00:00:00.000Z'), timeArg(to, 'to', '9999-12-31T23:59:59.999Z'), limitArg(limit, 10));
      return serve('search', query, ids(rows));
    },

    /** The newest captures first. */
    recent({ limit } = {}) {
      return serve('recent', 'recent', ids(memory.prepare('SELECT capture_id FROM doc ORDER BY sequence DESC LIMIT ?').all(limitArg(limit, 10))));
    },

    /** Everything captured between two times, in the order captured. */
    timeline({ from, to, limit } = {}) {
      const end = timeArg(to, 'to', new Date().toISOString());
      const start = timeArg(from, 'from', new Date(Date.parse(end) - HOUR).toISOString());
      const rows = memory.prepare('SELECT capture_id FROM doc WHERE captured_at >= ? AND captured_at <= ? ORDER BY captured_at, sequence LIMIT ?')
        .all(start, end, limitArg(limit, 100));
      return serve('timeline', `${start}/${end}`, ids(rows));
    },

    /** What was said between two times, in order: from the microphone (input), this Mac (output), or both. */
    transcript({ from, to, device, limit } = {}) {
      if (device != null && device !== 'input' && device !== 'output') throw new RangeError('device must be input or output');
      const end = timeArg(to, 'to', new Date().toISOString());
      const start = timeArg(from, 'from', new Date(Date.parse(end) - HOUR).toISOString());
      const rows = memory.prepare(`
        SELECT capture_id FROM doc WHERE capture_type = 'audio_transcript' AND captured_at >= ? AND captured_at <= ?
          AND (? IS NULL OR source_app = ?)
        ORDER BY captured_at, sequence LIMIT ?
      `).all(start, end, device ?? null, device ?? null, limitArg(limit, 100));
      return serve('transcript', `${start}/${end}/${device ?? ''}`, ids(rows));
    },

    /**
     * What the person is doing now: the latest session; the latest activity,
     * which says so if the person is idle or locked now; the session's latest
     * screen text; and anything said in the five minutes before this call.
     */
    now() {
      return consistent(() => {
        const session = sessions().at(-1) ?? null;
        const end = session?.ended_at ?? '9999-12-31T23:59:59.999Z';
        const latest = memory.prepare("SELECT capture_id FROM doc WHERE capture_type = 'activity' ORDER BY captured_at DESC, sequence DESC LIMIT 1").get();
        const screen = memory.prepare(`
          SELECT capture_id FROM doc WHERE capture_type = 'screen_text' AND captured_at >= ? AND captured_at < ?
          ORDER BY captured_at DESC, sequence DESC LIMIT 1
        `).get(session?.started_at ?? '9999-12-31T23:59:59.999Z', end);
        const said = memory.prepare(`
          SELECT capture_id FROM doc WHERE capture_type = 'audio_transcript' AND captured_at >= ?
          ORDER BY captured_at DESC, sequence DESC LIMIT 1
        `).get(new Date(Date.now() - 5 * 60_000).toISOString());
        // With no session yet (only idle or locked time so far), the latest activity still says so.
        const wanted = [...new Set([session?.capture_ids.at(-1), latest?.capture_id, screen?.capture_id, said?.capture_id].filter(Boolean))];
        return { session, envelopes: serve('now', 'now', wanted) };
      });
    },

    /**
     * One session, by id, and everything captured during it, in order: from
     * its start up to, not including, the capture that ended it.
     */
    session({ id, limit } = {}) {
      if (typeof id !== 'string') throw new RangeError('id must be a session id');
      const max = limitArg(limit, 100);
      return consistent(() => {
        const session = sessions().find((s) => s.id === id) ?? null;
        if (!session) return { session: null, envelopes: serve('session', id, []) };
        const rows = memory.prepare('SELECT capture_id FROM doc WHERE captured_at >= ? AND captured_at < ? ORDER BY captured_at, sequence LIMIT ?')
          .all(session.started_at, session.ended_at ?? '9999-12-31T23:59:59.999Z', max);
        return { session, envelopes: serve('session', id, ids(rows)) };
      });
    },
  };

  /**
   * A session answer computed from memory and served through the grant, with
   * nothing revoked in between: a session is derived from several captures,
   * and the store only re-checks the envelopes it serves. If anything was
   * revoked meanwhile, memory is brought up to date and the answer computed
   * again.
   */
  function consistent(answer) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const result = answer();
      if (!revokedSinceRefresh()) return result;
      refresh();
    }
    // Never an answer known to be stale: the caller can ask again.
    throw new ChangedError('captures were revoked while this was being answered, three times over: ask again');
  }

  return {
    /** Runs a tool, after bringing memory up to date with the store. */
    call(name, args) {
      const tool = tools[name];
      if (!tool) throw new Error(`unknown tool: ${name}`);
      refresh();
      return tool(args ?? {});
    },
    close: () => memory.close(),
  };
}
