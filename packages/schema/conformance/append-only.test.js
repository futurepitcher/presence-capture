import assert from 'node:assert/strict';
import test from 'node:test';
import { openStore } from '../src/store.js';

test('R1: capture events cannot be updated or deleted', () => {
  const store = openStore();
  const id = store.appendCapture({
    captureType: 'screen_text', source: 'screen', privacyLevel: 'sensitive', contentText: 'x',
  });

  assert.throws(
    () => store.db.prepare('UPDATE capture_event SET privacy_level = ? WHERE capture_id = ?')
      .run('standard', id),
    /append-only/,
    'a capture event was downgraded in place',
  );
  assert.throws(
    () => store.db.prepare('DELETE FROM capture_event WHERE capture_id = ?').run(id),
    /append-only/,
  );
  store.close();
});

test('R1: payloads are content-addressed and deduplicated', () => {
  const store = openStore();
  const a = store.putPayload({ bytes: 'frame-bytes', mediaType: 'image/heic', storageUri: 'seg/1#0' });
  const b = store.putPayload({ bytes: 'frame-bytes', mediaType: 'image/heic', storageUri: 'seg/9#4' });
  assert.equal(a, b, 'identical bytes produced different payload hashes');
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.equal(store.db.prepare('SELECT COUNT(*) AS n FROM capture_payload').get().n, 1);
  store.close();
});

test('R5: an unknown privacy level is rejected by the schema', () => {
  const store = openStore();
  assert.throws(
    () => store.appendCapture({
      captureType: 'screen_text', source: 'screen', privacyLevel: 'public',
    }),
    /CHECK|constraint/i,
  );
  store.close();
});

test('R6: classification is opaque, so any taxonomy fits', () => {
  const store = openStore();
  for (const classification of ['work', 'Gesundheit', 'projects/alpha', null]) {
    store.appendCapture({
      captureType: 'activity', source: 'activity', privacyLevel: 'standard', classification,
    });
  }
  assert.equal(store.db.prepare('SELECT COUNT(*) AS n FROM capture_event').get().n, 4);
  store.close();
});
