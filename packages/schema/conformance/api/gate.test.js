import assert from 'node:assert/strict';
import test from 'node:test';
import { createGate } from '../../src/gate.js';
import { openStore } from '../../src/store.js';

const heard = { kind: 'audio', at: '2026-10-06T09:00:00.000Z', device: 'input', transcript: 'we agreed to ship on friday', dedupe: 'utterance-1' };

const count = (store) => store.db.prepare('SELECT COUNT(*) AS n FROM capture_event').get().n;

test('gate: audio whose transcript fails to write leaves no segment, and the same observation retried lands whole', () => {
  const store = openStore();
  const gate = createGate(store);

  // The transcript's write fails (a full disk, say) after its segment's.
  store.db.exec(`
    CREATE TEMP TRIGGER transcript_fails BEFORE INSERT ON capture_event WHEN NEW.capture_type = 'audio_transcript'
    BEGIN SELECT RAISE(ABORT, 'disk full'); END
  `);
  assert.throws(() => gate.ingest(heard), /disk full/);
  assert.equal(count(store), 0, 'a segment was kept without its transcript');

  store.db.exec('DROP TRIGGER transcript_fails');
  gate.ingest(heard);
  assert.equal(gate.stats.duplicates, 0, 'the retry was taken for a duplicate: the failed write kept its dedupe key');
  assert.equal(gate.stats.appended, 2);
  const [segment, transcript] = gate.stats.captureIds;
  assert.equal(store.db.prepare('SELECT derived_from FROM capture_event WHERE capture_id = ?').get(transcript).derived_from, segment);
  assert.equal(store.contentText(transcript), 'we agreed to ship on friday');
  store.close();
});

test('gate: an observation stamped in the future is refused, since nothing could Forget it', () => {
  const store = openStore();
  const gate = createGate(store, { source: 'sensor:clock' });
  gate.ingest({ kind: 'screen', at: '2200-01-01T00:00:00.000Z', app: 'Notes', window: 'Plans', text: 'from the future' });
  gate.ingest({ kind: 'screen', at: new Date(Date.now() + 60_000).toISOString(), app: 'Notes', window: 'Plans', text: 'a clock a minute fast' });
  assert.equal(gate.stats.invalid, 1);
  assert.equal(count(store), 1, 'a clock a little fast is still kept');
  store.close();
});

test('gate: app, bundle and device names are kept short, with no control characters', () => {
  const store = openStore();
  const gate = createGate(store, { source: 'sensor:names' });
  gate.ingest({ kind: 'activity', at: '2026-10-06T09:00:00.000Z', app: `No\ntes${'x'.repeat(1000)}`, window: 'Plans', state: 'active' });
  const app = store.db.prepare('SELECT source_app FROM capture_event').get().source_app;
  assert.equal([...app].length, 256);
  assert.ok(app.startsWith('Notesxxx'), app.slice(0, 20));
  store.close();
});

test('gate: an observation stamped inside a forgotten range is refused and counted, not taken for a duplicate', () => {
  const store = openStore();
  const gate = createGate(store);
  store.revoke({ scopeKind: 'time_range', scopeValue: '2026-10-06T08:55:00.000Z/2026-10-06T09:10:00.000Z' });

  gate.ingest(heard);
  gate.ingest({ kind: 'screen', at: '2026-10-06T09:01:00.000Z', app: 'Notes', window: 'Plans', text: 'read while it was forgotten' });
  assert.equal(gate.stats.refused, 2);
  assert.equal(gate.stats.duplicates, 0);
  assert.equal(count(store), 0);
  store.close();
});
