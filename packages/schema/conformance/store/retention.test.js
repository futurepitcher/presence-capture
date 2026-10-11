import assert from 'node:assert/strict';
import test from 'node:test';
import { query } from './inspect.js';
import { screenText, withStore } from './helpers.js';

const NOW = '2026-10-20T12:00:00.000Z';

async function seed(call) {
  const { capture_id: old } = await call('append', screenText('three weeks ago', { captured_at: '2026-09-29T12:00:00.000Z' }));
  const { capture_id: recent } = await call('append', screenText('yesterday', { captured_at: '2026-10-19T12:00:00.000Z' }));
  return { old, recent };
}

test('store R12: retention is a time_range revocation with reason retention, and erases', () => withStore(async ({ call, path }) => {
  const { old, recent } = await seed(call);
  const { revocation_id: rev, revoked_capture_ids: revoked } = await call('retain', { days: 14, now: NOW });

  assert.deepEqual(revoked, [old]);
  const [row] = query(path, 'SELECT scope_kind, reason FROM revocation WHERE revocation_id = ?', rev);
  assert.deepEqual({ ...row }, { scope_kind: 'time_range', reason: 'retention' });
  assert.equal(query(path, 'SELECT keys_destroyed FROM erasure_receipt WHERE revocation_id = ?', rev)[0].keys_destroyed, 1);
  assert.deepEqual(await call('content', { capture_id: old }), { text: null });
  assert.deepEqual(await call('content', { capture_id: recent }), { text: 'yesterday' });
}));

test('store R12: retention with nothing old enough records nothing', () => withStore(async ({ call, path }) => {
  await seed(call);
  await call('retain', { days: 14, now: NOW });
  assert.deepEqual(await call('retain', { days: 14, now: NOW }), { revocation_id: null, revoked_capture_ids: [] });
  assert.equal(query(path, 'SELECT COUNT(*) AS n FROM revocation')[0].n, 1);
}));

test('store R12: retention takes what was derived from what expired (R10)', () => withStore(async ({ call }) => {
  const { old } = await seed(call);
  const { capture_id: derived } = await call('append', {
    capture_type: 'audio_transcript', source: 'ambient_audio', privacy_level: 'standard',
    content_text: 'said later', derived_from: old, captured_at: '2026-10-19T13:00:00.000Z',
  });
  await call('retain', { days: 14, now: NOW });
  assert.deepEqual(await call('content', { capture_id: derived }), { text: null });
}));
