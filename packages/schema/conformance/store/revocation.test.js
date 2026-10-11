import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { query } from './inspect.js';
import { appendAudioChain, screenText, withStore } from './helpers.js';

test('store R2: a revocation is recorded as an event and cannot be unmade', () => withStore(async ({ call, path }) => {
  const { capture_id: id } = await call('append', screenText('x'));
  const { revocation_id: rev } = await call('revoke', { scope_kind: 'capture', scope_value: id, reason: 'mine' });

  const [row] = query(path, 'SELECT * FROM revocation WHERE revocation_id = ?', rev);
  assert.equal(row.scope_kind, 'capture');
  assert.equal(row.reason, 'mine');

  const db = new DatabaseSync(path);
  try {
    assert.throws(() => db.prepare('DELETE FROM revocation WHERE revocation_id = ?').run(rev));
  } finally {
    db.close();
  }
}));

test('store R3: every projection is pruned, with one receipt each', () => withStore(async ({ call, path }) => {
  const { audio, transcript } = await appendAudioChain(call);
  await call('register_projection', { name: 'text_index', kind: 'index' });
  await call('register_projection', { name: 'vectors', kind: 'vector' });
  await call('add_projection_entry', { projection: 'text_index', capture_id: transcript, entry_ref: 'fts:1' });
  await call('add_projection_entry', { projection: 'vectors', capture_id: transcript, entry_ref: 'vec:1' });
  await call('add_projection_entry', { projection: 'vectors', capture_id: audio, entry_ref: 'vec:0' });

  const { revocation_id: rev } = await call('revoke', { scope_kind: 'capture', scope_value: audio });

  assert.equal(query(path, 'SELECT COUNT(*) AS n FROM projection_entry')[0].n, 0, 'projection entries survived');
  const receipts = query(path, 'SELECT * FROM projection_revocation WHERE revocation_id = ? ORDER BY projection_name', rev);
  assert.deepEqual(receipts.map((r) => [r.projection_name, r.entries_removed]), [['text_index', 1], ['vectors', 2]]);
}));

test('store R10: revocation cascades through derived_from, transitively', () => withStore(async ({ call, path }) => {
  const { audio, transcript, alignment } = await appendAudioChain(call);
  const { revoked_capture_ids: revoked } = await call('revoke', { scope_kind: 'capture', scope_value: audio });

  assert.deepEqual([...revoked].sort(), [audio, transcript, alignment].sort());
  const rows = query(path, 'SELECT capture_id, cascaded FROM revoked_capture');
  assert.deepEqual(
    Object.fromEntries(rows.map((r) => [r.capture_id, r.cascaded])),
    { [audio]: 0, [transcript]: 1, [alignment]: 1 },
  );
}));

test('store R11: revocation erases content and writes an erasure receipt', () => withStore(async ({ call, path }) => {
  const { audio, transcript } = await appendAudioChain(call);
  const { capture_id: kept } = await call('append', screenText('not revoked'));

  const { revocation_id: rev } = await call('revoke', { scope_kind: 'capture', scope_value: audio });

  const [receipt] = query(path, 'SELECT * FROM erasure_receipt WHERE revocation_id = ?', rev);
  assert.ok(receipt, 'no erasure receipt');
  assert.deepEqual(
    [receipt.keys_destroyed, receipt.contents_erased, receipt.payloads_erased],
    [3, 1, 1],
    'keys for audio, transcript and alignment; the transcript text; the audio payload',
  );
  assert.deepEqual(await call('content', { capture_id: transcript }), { text: null });
  assert.deepEqual(await call('payload', { capture_id: audio }), { bytes_base64: null });
  assert.deepEqual(await call('content', { capture_id: kept }), { text: 'not revoked' });
}));

test('store R2: each scope kind revokes what it names, and only that', () => withStore(async ({ call }) => {
  const ids = {};
  for (const [name, extra] of Object.entries({
    early: { captured_at: '2026-10-01T09:00:00.000Z' },
    notes: { source_app: 'com.apple.Notes', captured_at: '2026-10-05T09:00:00.000Z' },
    private: { privacy_level: 'sensitive', captured_at: '2026-10-05T10:00:00.000Z' },
    kept: { captured_at: '2026-10-05T11:00:00.000Z' },
  })) {
    ids[name] = (await call('append', screenText(name, extra))).capture_id;
  }

  const revoked = async (scope_kind, scope_value) =>
    (await call('revoke', { scope_kind, scope_value })).revoked_capture_ids;

  assert.deepEqual(await revoked('time_range', '2026-09-30T00:00:00.000Z/2026-10-02T00:00:00.000Z'), [ids.early]);
  assert.deepEqual(await revoked('source', 'com.apple.Notes'), [ids.notes]);
  assert.deepEqual(await revoked('privacy_level', 'sensitive'), [ids.private]);
  assert.deepEqual(await call('content', { capture_id: ids.kept }), { text: 'kept' });
}));
