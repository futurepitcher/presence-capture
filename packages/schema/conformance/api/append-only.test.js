import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { openStore } from '../../src/store.js';

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

test('R1: payloads are content-addressed over their sealed bytes, apart from metadata', () => {
  const store = openStore();
  const id = store.appendCapture({
    captureType: 'audio_segment', source: 'ambient_audio', privacyLevel: 'standard',
    payload: { bytes: 'audio-bytes', mediaType: 'audio/wav' },
  });
  const { payload_hash: hash } = store.db
    .prepare('SELECT payload_hash FROM capture_event WHERE capture_id = ?').get(id);
  const { sealed } = store.db.prepare('SELECT sealed FROM payload_blob WHERE payload_hash = ?').get(hash);

  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.equal(hash, createHash('sha256').update(sealed).digest('hex'), 'hash is not over the stored bytes');
  assert.equal(store.payloadBytes(id).toString(), 'audio-bytes');
  store.close();
});

test('R1: identical payloads in two captures are sealed apart, so each can be erased alone', () => {
  const store = openStore();
  const append = () => store.appendCapture({
    captureType: 'audio_segment', source: 'ambient_audio', privacyLevel: 'standard',
    payload: { bytes: 'same-bytes', mediaType: 'audio/wav' },
  });
  const [a, b] = [append(), append()];
  store.revoke({ scopeKind: 'capture', scopeValue: a });
  assert.equal(store.payloadBytes(a), null, 'revoked payload still readable');
  assert.equal(store.payloadBytes(b).toString(), 'same-bytes', 'erasing one capture took the other');
  store.close();
});

test('R11: content is not in the event log', () => {
  const store = openStore();
  const columns = store.db.prepare("SELECT name FROM pragma_table_info('capture_event')").all()
    .map((c) => c.name);
  assert.ok(!columns.includes('content_text'), 'capture_event still carries content');
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

test('R11: a file store refuses to open without its master key, or with another', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-key-'));
  const path = join(dir, 'store.sqlite');
  try {
    const masterKey = randomBytes(32);
    const store = openStore(path, { masterKey });
    store.appendCapture({ captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'x' });
    store.close();

    assert.throws(() => openStore(path), /needs its masterKey/);
    assert.throws(() => openStore(path, { masterKey: randomBytes(32) }), /does not open this store/);
    const again = openStore(path, { masterKey });
    assert.equal(again.db.prepare('SELECT COUNT(*) AS n FROM capture_key').get().n, 1);
    again.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
