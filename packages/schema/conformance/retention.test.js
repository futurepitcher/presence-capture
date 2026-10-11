import assert from 'node:assert/strict';
import test from 'node:test';
import { openStore } from '../src/store.js';
import { scheduleRetention } from '../src/retention.js';

const NOW = new Date('2026-10-20T12:00:00.000Z');

function seed() {
  const store = openStore();
  const old = store.appendCapture({
    captureType: 'screen_text', source: 'screen', privacyLevel: 'standard',
    contentText: 'from three weeks ago', capturedAt: '2026-09-29T12:00:00.000Z',
  });
  const recent = store.appendCapture({
    captureType: 'screen_text', source: 'screen', privacyLevel: 'standard',
    contentText: 'from yesterday', capturedAt: '2026-10-19T12:00:00.000Z',
  });
  return { store, old, recent };
}

test('R12: retention is a revocation with reason retention, and erases like one', () => {
  const { store, old, recent } = seed();
  const result = store.retain({ days: 14, now: NOW });

  assert.deepEqual(result.revokedCaptureIds, [old]);
  const revocation = store.db.prepare('SELECT * FROM revocation WHERE revocation_id = ?')
    .get(result.revocationId);
  assert.equal(revocation.scope_kind, 'time_range');
  assert.equal(revocation.reason, 'retention');

  assert.equal(store.contentText(old), null, 'expired content still readable');
  assert.equal(store.contentText(recent), 'from yesterday', 'retention took recent content');
  const receipt = store.db.prepare('SELECT * FROM erasure_receipt WHERE revocation_id = ?')
    .get(result.revocationId);
  assert.equal(receipt.keys_destroyed, 1);
  store.close();
});

test('R12: retention with nothing old enough writes no revocation', () => {
  const { store } = seed();
  store.retain({ days: 14, now: NOW });
  assert.equal(store.retain({ days: 14, now: NOW }), null);
  assert.equal(store.db.prepare('SELECT COUNT(*) AS n FROM revocation').get().n, 1);
  store.close();
});

test('R12: retention reaches what was derived from expired captures (R10)', () => {
  const { store, old } = seed();
  const derived = store.appendCapture({
    captureType: 'audio_transcript', source: 'ambient_audio', privacyLevel: 'standard',
    contentText: 'said later about it', derivedFrom: old, capturedAt: '2026-10-19T13:00:00.000Z',
  });
  store.retain({ days: 14, now: NOW });
  assert.equal(store.contentText(derived), null);
  store.close();
});

test('R12: a retention period of zero or less is refused', () => {
  const { store } = seed();
  assert.throws(() => store.retain({ days: 0, now: NOW }), /positive/);
  store.close();
});

test('R12: the schedule runs retention on each tick until stopped', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { store, old } = seed();
  const runs = [];
  const schedule = scheduleRetention(store, {
    days: 14, everyMs: 3_600_000, now: () => NOW, onRun: (r) => runs.push(r),
  });

  t.mock.timers.tick(3_600_000);
  assert.equal(store.contentText(old), null);
  t.mock.timers.tick(3_600_000);
  assert.equal(runs.length, 2);
  assert.equal(runs[1], null, 'second tick revoked again with nothing to revoke');

  schedule.stop();
  t.mock.timers.tick(3_600_000);
  assert.equal(runs.length, 2, 'retention ran after stop');
  store.close();
});
