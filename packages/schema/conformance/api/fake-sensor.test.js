import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseFixture, replayFixture } from '../../src/fake-sensor.js';
import { openStore } from '../../src/store.js';

const fixture = parseFixture(readFileSync(new URL('../../fixtures/a-short-day.jsonl', import.meta.url), 'utf8'));

function replayed() {
  const store = openStore();
  const stats = replayFixture(store, fixture);
  const texts = stats.captureIds.map((id) => store.contentText(id) ?? '');
  return { store, stats, texts };
}

test('fake sensor: excluded windows never become captures (R8)', () => {
  const { store, stats, texts } = replayed();
  // The bank tab (user list), the lock screen (system), and its own window.
  assert.equal(stats.excluded, 4);
  for (const leaked of ['2,310.55', 'Enter Password', 'claude-code read 12']) {
    assert.ok(!texts.some((t) => t.includes(leaked)), `excluded content captured: ${leaked}`);
  }
  store.close();
});

test('fake sensor: secrets and personal identifiers are redacted before append', () => {
  const { store, stats, texts } = replayed();
  assert.equal(stats.redacted, 2);
  assert.ok(!texts.some((t) => t.includes('sk-ant-api03')), 'API key stored');
  assert.ok(!texts.some((t) => t.includes('dana@example.com')), 'email stored');
  assert.ok(texts.some((t) => t.includes('[API_KEY]')));
  store.close();
});

test('fake sensor: audio becomes a segment with a transcript derived from it (R10)', () => {
  const { store } = replayed();
  const transcripts = store.db.prepare(`
    SELECT t.capture_id, t.derived_from, a.capture_type AS parent_type
    FROM capture_event t JOIN capture_event a ON a.capture_id = t.derived_from
    WHERE t.capture_type = 'audio_transcript'
  `).all();
  assert.equal(transcripts.length, 2);
  assert.ok(transcripts.every((t) => t.parent_type === 'audio_segment'));

  store.revoke({ scopeKind: 'capture', scopeValue: transcripts[0].derived_from });
  assert.equal(store.contentText(transcripts[0].capture_id), null, 'transcript outlived its audio');
  store.close();
});

test('fake sensor: a URL is kept only where the observation established it', () => {
  const { store } = replayed();
  const urls = store.db.prepare('SELECT source_url FROM capture_event WHERE source_url IS NOT NULL').all();
  assert.deepEqual(urls.map((u) => u.source_url), ['https://developer.apple.com/documentation/speech/speechanalyzer']);
  store.close();
});

test('fake sensor: an excluded window keeps its time and state, never its app or window', () => {
  const { store, stats, texts } = replayed();
  const locked = stats.captureIds
    .map((id, i) => ({ id, text: texts[i] }))
    .filter(({ text }) => text.includes('"excluded":true'));
  assert.deepEqual(locked.map(({ text }) => JSON.parse(text)), [{ state: 'locked', excluded: true }]);
  const [row] = store.db.prepare('SELECT source_app FROM capture_event WHERE capture_id = ?').all(locked[0].id);
  assert.equal(row.source_app, null);
  store.close();
});

test('fake sensor: the whole day lands, and nothing it captured is in plaintext in the log', () => {
  const { store, stats } = replayed();
  // 8 kept screen and activity observations, 2 calls as segment and
  // transcript, and the lock as state alone.
  assert.equal(stats.appended, 13);
  const log = JSON.stringify(store.db.prepare('SELECT * FROM capture_event').all());
  assert.ok(!log.includes('Q4 plan'), 'content found in the event log');
  store.close();
});
