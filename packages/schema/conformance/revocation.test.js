import assert from 'node:assert/strict';
import test from 'node:test';
import { countEntries, seedAudioChain } from './helpers.js';
import { openStore } from '../src/store.js';

test('R2: revocation is an event, and cannot be unmade', () => {
  const { store, audioId } = seedAudioChain();
  const { revocationId } = store.revoke({ scopeKind: 'capture', scopeValue: audioId });

  const row = store.db
    .prepare('SELECT * FROM revocation WHERE revocation_id = ?')
    .get(revocationId);
  assert.equal(row.scope_kind, 'capture');

  assert.throws(
    () => store.db.prepare('DELETE FROM revocation WHERE revocation_id = ?').run(revocationId),
    /append-only/,
  );
  store.close();
});

test('R3: revocation propagates into every projection, with a receipt', () => {
  const { store, audioId } = seedAudioChain();
  assert.equal(countEntries(store, 'vectors'), 2);
  assert.equal(countEntries(store, 'text_index'), 1);

  const { revocationId } = store.revoke({ scopeKind: 'capture', scopeValue: audioId });

  // Both projections pruned — including the transcript's entries, reached via
  // the derived_from chain.
  assert.equal(countEntries(store, 'vectors'), 0, 'vector entries survived revocation');
  assert.equal(countEntries(store, 'text_index'), 0, 'index entries survived revocation');

  // And a receipt exists per projection, which is what lets an implementation
  // claim R3 rather than merely assert it.
  const receipts = store.db
    .prepare('SELECT * FROM projection_revocation WHERE revocation_id = ? ORDER BY projection_name')
    .all(revocationId);
  assert.equal(receipts.length, 2);
  assert.equal(receipts.reduce((n, r) => n + r.entries_removed, 0), 3);
  store.close();
});

test('R10: revoking audio revokes its transcript and the transcript vectors', () => {
  const { store, audioId, transcriptId } = seedAudioChain();
  store.revoke({ scopeKind: 'capture', scopeValue: audioId, reason: 'user revoked the meeting' });

  const revoked = store.db
    .prepare('SELECT capture_id, cascaded FROM revoked_capture ORDER BY cascaded')
    .all();
  assert.deepEqual(
    revoked.map((r) => r.capture_id).sort(),
    [audioId, transcriptId].sort(),
    'transcript was not cascaded',
  );
  assert.equal(revoked.find((r) => r.capture_id === transcriptId).cascaded, 1);

  const stillIndexed = store.db
    .prepare('SELECT COUNT(*) AS n FROM projection_entry WHERE capture_id = ?')
    .get(transcriptId).n;
  assert.equal(stillIndexed, 0, 'transcript embeddings survived audio revocation');
  store.close();
});

test('R10: cascade is transitive through an alignment derived from a transcript', () => {
  const { store, audioId, transcriptId } = seedAudioChain();
  const alignmentId = store.appendCapture({
    captureType: 'audio_alignment',
    source: 'ambient_audio',
    privacyLevel: 'standard',
    derivedFrom: transcriptId,
  });
  store.addProjectionEntry({ projection: 'vectors', captureId: alignmentId, entryRef: 'vec:2' });

  store.revoke({ scopeKind: 'capture', scopeValue: audioId });

  const revoked = store.db.prepare('SELECT capture_id FROM revoked_capture').all()
    .map((r) => r.capture_id);
  assert.ok(revoked.includes(alignmentId), 'alignment two hops down survived');
  assert.equal(countEntries(store, 'vectors'), 0);
  store.close();
});

test('R7: a duplicate dedupe_key is rejected rather than stored twice', () => {
  const store = openStore();
  store.appendCapture({
    captureType: 'screen_frame', source: 'screen', privacyLevel: 'standard', dedupeKey: 'frame-abc',
  });
  assert.throws(
    () => store.appendCapture({
      captureType: 'screen_frame', source: 'screen', privacyLevel: 'standard', dedupeKey: 'frame-abc',
    }),
    /UNIQUE/i,
  );
  store.close();
});
