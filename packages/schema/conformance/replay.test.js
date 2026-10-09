import assert from 'node:assert/strict';
import test from 'node:test';
import { seedAudioChain } from './helpers.js';
import { openStore } from '../src/store.js';

const deriveText = (e) => (e.content_text ? { id: e.capture_id, text: e.content_text } : undefined);

test('R4: replaying the same stream twice produces the same state hash', () => {
  const { store } = seedAudioChain();
  const first = store.replay({ consumer: 'text_index', derive: deriveText });
  const second = store.replay({ consumer: 'text_index', derive: deriveText });
  assert.equal(first.stateHash, second.stateHash);
  assert.equal(first.throughSequence, second.throughSequence);
  store.close();
});

test('R4: a receipt and watermark record the position reached', () => {
  const { store } = seedAudioChain();
  const { stateHash, throughSequence } = store.replay({ consumer: 'text_index', derive: deriveText });

  const receipt = store.db
    .prepare('SELECT * FROM replay_receipt WHERE consumer = ? AND through_sequence = ?')
    .get('text_index', throughSequence);
  assert.equal(receipt.state_hash, stateHash);

  const watermark = store.db
    .prepare('SELECT * FROM replay_watermark WHERE consumer = ?')
    .get('text_index');
  assert.equal(watermark.last_sequence, throughSequence);
  store.close();
});

test('R4: revocation changes the replayed state, deterministically', () => {
  const { store, audioId } = seedAudioChain();
  const before = store.replay({ consumer: 'text_index', derive: deriveText });
  assert.equal(before.state.length, 1);

  store.revoke({ scopeKind: 'capture', scopeValue: audioId });

  const after = store.replay({ consumer: 'text_index', derive: deriveText });
  assert.equal(after.state.length, 0, 'revoked content reappeared on replay');
  assert.notEqual(after.stateHash, before.stateHash);

  const again = store.replay({ consumer: 'text_index', derive: deriveText });
  assert.equal(again.stateHash, after.stateHash);
  store.close();
});

test('R4: replay order follows sequence, not insertion timestamps', () => {
  const store = openStore();
  store.appendCapture({
    captureType: 'screen_text', source: 'screen', privacyLevel: 'standard',
    contentText: 'second', capturedAt: '2026-01-02T00:00:00Z',
  });
  store.appendCapture({
    captureType: 'screen_text', source: 'screen', privacyLevel: 'standard',
    contentText: 'first', capturedAt: '2026-01-01T00:00:00Z',
  });
  const { state } = store.replay({ consumer: 'c', derive: deriveText });
  assert.deepEqual(state.map((s) => s.text), ['second', 'first']);
  store.close();
});
