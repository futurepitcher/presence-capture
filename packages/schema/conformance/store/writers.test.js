import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { startDriver } from '../driver-client.js';
import { query } from './inspect.js';
import { screenText, withStore } from './helpers.js';

// What holds when the store has more than one writer: the daemon capturing,
// the command line forgetting, an MCP server recording what it served. Each
// test opens a second connection of its own, through the driver or directly.

/** A second driver on the same store, as another process would open it. */
async function secondWriter(path, masterKey) {
  const other = startDriver();
  await other.call('open', { path, master_key_hex: masterKey.toString('hex') });
  return other;
}

test('store R2: a revocation resolves its scope under the write lock, so a capture committed while it waited is revoked', () => withStore(async ({ call, path }) => {
  await call('append', screenText('before', { captured_at: '2026-10-06T09:00:00.000Z' }));

  // Another writer holds the lock, and commits a capture inside the range while the revocation waits for it.
  const other = new DatabaseSync(path);
  other.exec('PRAGMA busy_timeout = 5000');
  other.exec('BEGIN IMMEDIATE');
  const pending = call('revoke', { scope_kind: 'time_range', scope_value: '2026-10-06T08:00:00.000Z/2026-10-06T10:00:00.000Z' });
  await sleep(300);
  other.prepare(`
    INSERT INTO capture_event (capture_id, sequence, captured_at, capture_type, source, privacy_level)
    VALUES ('cap_meanwhile', (SELECT COALESCE(MAX(s), 0) + 1 FROM (
      SELECT MAX(sequence) AS s FROM capture_event UNION ALL SELECT MAX(sequence) AS s FROM revocation)),
      '2026-10-06T09:30:00.000Z', 'screen_text', 'screen', 'standard')
  `).run();
  other.exec('COMMIT');
  other.close();

  const { revoked_capture_ids: revoked } = await pending;
  assert.ok(revoked.includes('cap_meanwhile'), 'the scope was resolved before the write lock: a capture committed in range was left out');
}));

test('store R13: an append stamped inside a revoked time range is refused, whichever writer makes it', () => withStore(async ({ call, path, masterKey }) => {
  const other = await secondWriter(path, masterKey);
  try {
    await call('revoke', { scope_kind: 'time_range', scope_value: '2026-10-06T09:00:00Z/2026-10-06T09:15:00Z' });

    // Speech said at five past, written after the range was forgotten.
    await assert.rejects(other.call('append', screenText('said, then forgotten', { captured_at: '2026-10-06T09:05:00.000Z' })), { code: 'constraint' });
    await assert.rejects(call('append', screenText('at the very end', { captured_at: '2026-10-06T09:15:00.000Z' })), { code: 'constraint' });
    await assert.rejects(other.call('append_all', { captures: [screenText('in a batch', { captured_at: '2026-10-06T09:00:00Z' })] }), { code: 'constraint' });
    await other.call('append', screenText('after', { captured_at: '2026-10-06T09:15:00.001Z' }));
    assert.equal(query(path, "SELECT COUNT(*) AS n FROM capture_event WHERE captured_at <= '2026-10-06T09:15:00.000Z'")[0].n, 0);

    // The range is kept in the form captured_at is, so the comparison is exact.
    assert.equal(query(path, 'SELECT scope_value FROM revocation')[0].scope_value, '2026-10-06T09:00:00.000Z/2026-10-06T09:15:00.000Z');
  } finally {
    await other.close();
  }
}));

test('store R13: an append derived from a revoked capture is refused', () => withStore(async ({ call }) => {
  const { capture_id: audio } = await call('append', { capture_type: 'audio_segment', source: 'ambient_audio', privacy_level: 'standard' });
  await call('revoke', { scope_kind: 'capture', scope_value: audio });
  await assert.rejects(call('append', {
    capture_type: 'audio_transcript', source: 'ambient_audio', privacy_level: 'standard',
    content_text: 'the transcript of a forgotten segment', derived_from: audio,
  }), { code: 'constraint' });
}));

test('store R13: once retention has run, a late capture older than its cutoff is refused', () => withStore(async ({ call }) => {
  await call('append', screenText('three weeks ago', { captured_at: '2026-09-29T12:00:00.000Z' }));
  await call('retain', { days: 14, now: '2026-10-20T12:00:00.000Z' });
  await assert.rejects(call('append', screenText('arrived late', { captured_at: '2026-10-01T12:00:00.000Z' })), { code: 'constraint' });
  await call('append', screenText('within retention', { captured_at: '2026-10-19T12:00:00.000Z' }));
}));

test('store R3/R13: no projection entry is added for a capture another writer revoked', () => withStore(async ({ call, path, masterKey }) => {
  const other = await secondWriter(path, masterKey);
  try {
    await call('register_projection', { name: 'vectors', kind: 'vector' });
    const { capture_id: id } = await call('append', screenText('projected after it was revoked'));
    await call('revoke', { scope_kind: 'capture', scope_value: id });

    await assert.rejects(other.call('add_projection_entry', { projection: 'vectors', capture_id: id, entry_ref: 'vec:1' }), { code: 'constraint' });
    await assert.rejects(other.call('add_projection_entry', {
      projection: 'vectors', capture_id: id, entry_ref: 'vec:2', output_kind: 'vector', output_json: '[0.1]',
    }), { code: 'constraint' });
    assert.equal(query(path, 'SELECT COUNT(*) AS n FROM projection_entry')[0].n, 0);
  } finally {
    await other.close();
  }
}));

test('store R1: append_all writes every capture or none, so a failed batch leaves no segment and its dedupe key unused', () => withStore(async ({ call, path }) => {
  const segment = { capture_id: 'cap_segment', capture_type: 'audio_segment', source: 'ambient_audio', privacy_level: 'standard', dedupe_key: 'utterance-1' };
  const transcript = { capture_type: 'audio_transcript', source: 'ambient_audio', content_text: 'hello', extraction: 'asr', derived_from: 'cap_segment' };

  await assert.rejects(call('append_all', { captures: [segment, { ...transcript, privacy_level: 'public' }] }), { code: 'constraint' });
  assert.equal(query(path, 'SELECT COUNT(*) AS n FROM capture_event')[0].n, 0, 'a segment was kept without its transcript');

  // Retried whole: the dedupe key didn't outlive the failed batch.
  const { capture_ids: ids } = await call('append_all', { captures: [segment, { ...transcript, privacy_level: 'standard' }] });
  assert.equal(ids.length, 2);
  assert.equal(ids[0], 'cap_segment');
  assert.equal(query(path, 'SELECT derived_from FROM capture_event WHERE capture_id = ?', ids[1])[0].derived_from, 'cap_segment');
  assert.deepEqual(await call('content', { capture_id: ids[1] }), { text: 'hello' });
}));

test('store ADR 0001: a grant revoked by another writer is refused on the next read', () => withStore(async ({ call, path, masterKey }) => {
  await call('append', screenText('readable until the grant goes'));
  const { grant_id: grant } = await call('issue_grant', { client_id: 'agent', expires_at: '2099-01-01T00:00:00.000Z' });
  assert.equal((await call('read', { grant_id: grant, tool: 'recent' })).envelopes.length, 1);

  const other = await secondWriter(path, masterKey);
  try {
    await other.call('revoke_grant', { grant_id: grant });
  } finally {
    await other.close();
  }
  await assert.rejects(call('read', { grant_id: grant, tool: 'recent' }), { code: 'denied' });
}));
