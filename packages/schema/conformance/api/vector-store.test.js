import assert from 'node:assert/strict';
import test from 'node:test';
import { openStore } from '../../src/store.js';
import { bindVectorStore, createInMemoryVectorStore } from '../../src/vector-store.js';

/**
 * Run this file against your own adapter to claim R3 conformance for a
 * substituted backend. Replace createInMemoryVectorStore with your factory.
 */
const makeVectorStore = createInMemoryVectorStore;

test('R3: revocation prunes the vector backend, not just the index table', () => {
  const store = openStore();
  const vectors = makeVectorStore();
  const bound = bindVectorStore(store, vectors);

  const audioId = store.appendCapture({
    captureType: 'audio_segment', source: 'ambient_audio', privacyLevel: 'standard',
  });
  const transcriptId = store.appendCapture({
    captureType: 'audio_transcript', source: 'ambient_audio', privacyLevel: 'standard',
    contentText: 'quarterly numbers', extraction: 'asr', derivedFrom: audioId,
  });

  bound.index({ captureId: audioId, entryRef: 'vec:a', vector: [0.1, 0.2] });
  bound.index({ captureId: transcriptId, entryRef: 'vec:t', vector: [0.3, 0.4] });
  assert.equal(vectors.size(), 2);

  const result = bound.revoke({ scopeKind: 'capture', scopeValue: audioId });

  assert.equal(vectors.size(), 0, 'vectors survived revocation in the backend');
  assert.equal(result.vectorEntriesRemoved, 2);
  assert.deepEqual(vectors.entryRefsFor(transcriptId), [],
    'transcript embeddings survived revocation of their source audio');

  const receipt = store.db
    .prepare('SELECT entries_removed FROM projection_revocation WHERE projection_name = ?')
    .get('vectors');
  assert.equal(receipt.entries_removed, 2);
  store.close();
});

test('R3: a backend that keeps entries fails this test', () => {
  const store = openStore();
  // A deliberately non-conformant backend: it ignores deletes.
  const leaky = { ...createInMemoryVectorStore(), deleteByCaptureIds: () => 0 };
  const bound = bindVectorStore(store, leaky, 'leaky');

  const id = store.appendCapture({
    captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'x',
  });
  bound.index({ captureId: id, entryRef: 'vec:1', vector: [1] });
  const result = bound.revoke({ scopeKind: 'capture', scopeValue: id });

  // The store's own bookkeeping is correct, but the backend lied — and the
  // mismatch is what a conformance run surfaces.
  assert.equal(result.vectorEntriesRemoved, 0);
  assert.notEqual(leaky.size(), 0, 'fixture is wrong: the leaky backend should still hold entries');
  store.close();
});

test('R3/R13: a vector for a revoked capture is refused before it reaches the backend', () => {
  const store = openStore();
  const vectors = makeVectorStore();
  const bound = bindVectorStore(store, vectors);
  const id = store.appendCapture({ captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'gone' });
  bound.revoke({ scopeKind: 'capture', scopeValue: id });

  assert.throws(() => bound.index({ captureId: id, entryRef: 'vec:late', vector: [0.5, 0.6] }), { name: 'RevokedError' });
  assert.equal(vectors.size(), 0, 'the backend kept a vector the store refused to record');
});

test('R3: an index whose backend failed can be retried', () => {
  const store = openStore();
  const backend = makeVectorStore();
  let failures = 1;
  const flaky = { ...backend, upsert: (entry) => (failures-- > 0 ? (() => { throw new Error('backend unavailable'); })() : backend.upsert(entry)) };
  const bound = bindVectorStore(store, flaky);
  const id = store.appendCapture({ captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'retried' });

  assert.throws(() => bound.index({ captureId: id, entryRef: 'vec:1', vector: [0.1] }), /backend unavailable/);
  bound.index({ captureId: id, entryRef: 'vec:1', vector: [0.1] });
  assert.equal(backend.size(), 1);
});
