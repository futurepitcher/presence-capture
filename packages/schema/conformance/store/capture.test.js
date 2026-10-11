import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { openStore } from '../../src/store.js';
import { startDriver } from '../driver-client.js';
import { query, unsealPerSpec } from './inspect.js';
import { screenText, withStore } from './helpers.js';

test('store R1: capture events cannot be updated or deleted', () => withStore(async ({ call, path }) => {
  const { capture_id: id } = await call('append', screenText('x', { privacy_level: 'sensitive' }));

  const db = new DatabaseSync(path);
  try {
    assert.throws(() => db.prepare("UPDATE capture_event SET privacy_level = 'standard' WHERE capture_id = ?").run(id));
    assert.throws(() => db.prepare('DELETE FROM capture_event WHERE capture_id = ?').run(id));
  } finally {
    db.close();
  }
  assert.equal(query(path, 'SELECT privacy_level FROM capture_event WHERE capture_id = ?', id)[0].privacy_level, 'sensitive');
}));

test('store R5: an unknown privacy level is refused', () => withStore(async ({ call }) => {
  await assert.rejects(call('append', screenText('x', { privacy_level: 'public' })), { code: 'constraint' });
}));

test('store R6: classification is opaque, so any taxonomy fits', () => withStore(async ({ call, path }) => {
  for (const classification of ['work', 'Gesundheit', 'projects/alpha', null]) {
    await call('append', { capture_type: 'activity', source: 'activity', privacy_level: 'standard', classification });
  }
  assert.equal(query(path, 'SELECT COUNT(*) AS n FROM capture_event')[0].n, 4);
}));

test('store R7: a duplicate dedupe_key is refused rather than stored twice', () => withStore(async ({ call, path }) => {
  await call('append', screenText('a', { dedupe_key: 'frame-abc' }));
  await assert.rejects(call('append', screenText('a', { dedupe_key: 'frame-abc' })), { code: 'constraint' });
  assert.equal(query(path, 'SELECT COUNT(*) AS n FROM capture_event')[0].n, 1);
}));

test('store R11: no column of the event log holds content', () => withStore(async ({ call, path }) => {
  await call('append', screenText('never in the log'));
  const columns = query(path, "SELECT name FROM pragma_table_info('capture_event')").map((c) => c.name);
  assert.ok(!columns.includes('content_text'));
  const rows = query(path, 'SELECT * FROM capture_event');
  assert.ok(!JSON.stringify(rows).includes('never in the log'));
}));

test('store R11: text is sealed as SCHEMA.md defines, so any implementation can open it', () => withStore(async ({ call, path, masterKey }) => {
  const { capture_id: id } = await call('append', screenText('sealed the agreed way'));

  const [{ wrapped_key: wrapped }] = query(path, 'SELECT wrapped_key FROM capture_key WHERE capture_id = ?', id);
  const key = unsealPerSpec(masterKey, wrapped, `key:${id}`);
  assert.ok(key, 'the data key does not unwrap with the master key and AAD key:<capture_id>');
  assert.equal(key.length, 32);

  const [{ text_sealed: sealed }] = query(path, 'SELECT text_sealed FROM capture_content WHERE capture_id = ?', id);
  assert.equal(unsealPerSpec(key, sealed, `text:${id}`)?.toString(), 'sealed the agreed way');
  assert.equal(unsealPerSpec(key, sealed, 'text:another-capture'), null, 'the AAD does not bind the text to its capture');

  assert.deepEqual(await call('content', { capture_id: id }), { text: 'sealed the agreed way' });
}));

test('store R1/R11: a payload is sealed, and addressed by the hash of its sealed bytes', () => withStore(async ({ call, path, masterKey }) => {
  const { capture_id: id } = await call('append', {
    capture_type: 'audio_segment', source: 'ambient_audio', privacy_level: 'standard',
    payload: { bytes_base64: Buffer.from('pcm-bytes').toString('base64'), media_type: 'audio/wav' },
  });
  const [row] = query(path, `
    SELECT e.payload_hash, p.byte_count, p.media_type, b.sealed, k.wrapped_key
    FROM capture_event e
    JOIN capture_payload p ON p.payload_hash = e.payload_hash
    LEFT JOIN payload_blob b ON b.payload_hash = e.payload_hash
    JOIN capture_key k ON k.capture_id = e.capture_id
    WHERE e.capture_id = ?
  `, id);
  assert.ok(row.sealed, 'this suite reads payloads from payload_blob or a file: storage_uri');
  assert.equal(row.payload_hash, createHash('sha256').update(row.sealed).digest('hex'));
  assert.equal(row.media_type, 'audio/wav');
  const key = unsealPerSpec(masterKey, row.wrapped_key, `key:${id}`);
  assert.equal(unsealPerSpec(key, row.sealed, `payload:${id}`)?.toString(), 'pcm-bytes');

  const { bytes_base64: back } = await call('payload', { capture_id: id });
  assert.equal(Buffer.from(back, 'base64').toString(), 'pcm-bytes');
}));

test('store R11: a store will not open with another master key', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-key-'));
  const path = join(dir, 'store.sqlite');
  const masterKey = randomBytes(32).toString('hex');
  try {
    const first = startDriver();
    await first.call('open', { path, master_key_hex: masterKey });
    await first.call('append', screenText('x'));
    await first.close();

    const wrong = startDriver();
    await assert.rejects(wrong.call('open', { path, master_key_hex: randomBytes(32).toString('hex') }), { code: 'key' });
    await wrong.close();

    const right = startDriver();
    await right.call('open', { path, master_key_hex: masterKey });
    await right.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('store R9: a store written by this implementation opens in the reference, which serves it', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-interop-'));
  const path = join(dir, 'store.sqlite');
  const masterKey = randomBytes(32);
  try {
    const driver = startDriver();
    await driver.call('open', { path, master_key_hex: masterKey.toString('hex') });
    const { capture_id: id } = await driver.call('append', screenText('written by one, read by another'));
    await driver.close();

    const reference = openStore(path, { masterKey });
    assert.equal(reference.contentText(id), 'written by one, read by another');
    reference.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
