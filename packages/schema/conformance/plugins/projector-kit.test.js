import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseFixture, replayFixture } from '../../src/fake-sensor.js';
import { grantFor, loadProjector, manifestError, runProjector } from '../../src/projector-host.js';
import { openStore } from '../../src/store.js';
import { checkProjector } from './projector-kit.js';
import { constant, forever, stateful } from './wasm.js';

const MANIFEST = {
  projector: 'word-count', protocol: '1',
  projection: { name: 'word-count', kind: 'summary' },
  reads: { capture_types: ['screen_text', 'audio_transcript'], privacy_levels: ['standard'] },
  writes: { kinds: ['summary'] },
};
const OUTPUT = JSON.stringify({ entries: [{ ref: 'summary', kind: 'summary', value: { projected: true } }] });
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const day = () => {
  const store = openStore();
  replayFixture(store, parseFixture(readFileSync(new URL('../../fixtures/a-short-day.jsonl', import.meta.url), 'utf8')));
  return store;
};
const load = (bytes, manifest = MANIFEST) => loadProjector({ bytes, manifest, approvedSha256: sha(bytes) });

test('projector kit: a well-behaved projector passes, and its outputs are sealed and revocable', async () => {
  assert.deepEqual(await checkProjector({ bytes: constant(OUTPUT), manifest: MANIFEST }), []);
});

test('projector host: what a projector returns is kept by the store, under its capture\'s key', async () => {
  const store = day();
  const projector = load(constant(OUTPUT));
  const stats = await runProjector({ store, projector, grantId: grantFor(store, MANIFEST, { expiresAt: '2099-01-01T00:00:00Z' }) });
  assert.ok(stats.projected > 0);
  const [{ capture_id: id }] = store.db.prepare("SELECT capture_id FROM projection_entry WHERE projection_name = 'word-count'").all();
  assert.deepEqual(store.projectionOutputs({ projection: 'word-count', captureId: id }), [{ entryRef: 'summary', kind: 'summary', value: { projected: true } }]);
  store.close();
});

test('projector attack refused: a module that imports anything (a way to call home)', () => {
  assert.throws(() => load(constant(OUTPUT, { importFetch: true })), /import nothing/);
});

test('projector attack refused: a module whose memory has no maximum', () => {
  assert.throws(() => load(constant(OUTPUT, { memory: { min: 1 } })), /maximum/);
});

test('projector attack refused: a module that isn\'t the one approved', () => {
  const bytes = constant(OUTPUT);
  assert.throws(() => loadProjector({ bytes, manifest: MANIFEST, approvedSha256: sha(constant('{"entries":[]}')) }), /not the approved module/);
});

test('projector attack contained: a module that never returns is stopped, and nothing is written', async () => {
  const store = day();
  const stats = await runProjector({ store, projector: load(forever()), grantId: grantFor(store, MANIFEST, { expiresAt: '2099-01-01T00:00:00Z' }), timeoutMs: 150 });
  assert.ok(stats.read > 0);
  assert.equal(stats.timedOut, stats.read);
  assert.equal(store.db.prepare('SELECT COUNT(*) AS n FROM projection_entry').get().n, 0);
  store.close();
});

test('projector attack contained: a module keeping state between captures gets a fresh instance for each', async () => {
  const first = JSON.stringify({ entries: [{ ref: 'call', kind: 'summary', value: 'first' }] });
  const then = JSON.stringify({ entries: [{ ref: 'call', kind: 'summary', value: 'carried over from another capture' }] });
  const store = day();
  const stats = await runProjector({ store, projector: load(stateful(first, then)), grantId: grantFor(store, MANIFEST, { expiresAt: '2099-01-01T00:00:00Z' }) });
  assert.ok(stats.projected > 1, 'needs more than one capture to show anything');
  const ids = store.db.prepare("SELECT capture_id FROM projection_entry WHERE projection_name = 'word-count'").all().map((r) => r.capture_id);
  for (const id of ids) assert.deepEqual(store.projectionOutputs({ projection: 'word-count', captureId: id })[0].value, 'first');
  store.close();
});

test('projector attack rejected: output that is too big, malformed, or of a kind its manifest does not write', async () => {
  const big = JSON.stringify({ entries: [{ ref: 'x', kind: 'summary', value: 'x'.repeat(70 * 1024) }] });
  const cases = {
    'over the output limit': constant(big, { memory: { min: 4, max: 4 } }),
    'not JSON': constant('not json'),
    'a kind not in its manifest': constant(JSON.stringify({ entries: [{ ref: 'v', kind: 'vector', value: [1, 2] }] })),
  };
  for (const [name, bytes] of Object.entries(cases)) {
    const failures = await checkProjector({ bytes, manifest: MANIFEST });
    assert.ok(failures.length > 0, `passed the kit with ${name}`);
  }
});

test('projector scope: it is served only what its manifest reads, through a grant, and logged', async () => {
  const store = day();
  const manifest = { ...MANIFEST, reads: { capture_types: ['screen_text'], privacy_levels: ['standard'] } };
  await runProjector({ store, projector: load(constant(OUTPUT), manifest), grantId: grantFor(store, manifest, { expiresAt: '2099-01-01T00:00:00Z' }) });
  const served = store.db.prepare(`
    SELECT DISTINCT e.capture_type FROM egress_record r, json_each(r.capture_ids) j
    JOIN capture_event e ON e.capture_id = j.value WHERE r.client_id = 'projector:word-count'
  `).all().map((r) => r.capture_type);
  assert.deepEqual(served, ['screen_text']);
  assert.equal(store.verifyEgressChain().ok, true);
  store.close();
});

test('projector manifest: sacred_mode can never be read, and names are checked', () => {
  assert.match(manifestError({ ...MANIFEST, reads: { capture_types: ['screen_text'], privacy_levels: ['sacred_mode'] } }), /grantable/);
  assert.match(manifestError({ ...MANIFEST, projector: 'Word Count' }), /names/);
  assert.equal(manifestError(MANIFEST), null);
});
