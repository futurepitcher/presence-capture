import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { headerError, observationError } from '../../src/observations.js';
import { runSensor } from '../../src/sensor-host.js';
import { openStore } from '../../src/store.js';
import { checkSensor } from './sensor-kit.js';

const GIT_ACTIVITY = new URL('../../../plugins/git-activity/sensor.mjs', import.meta.url).pathname;
const cases = JSON.parse(readFileSync(new URL('../../cases/observations.json', import.meta.url), 'utf8'));

for (const c of cases.headers) {
  test(`observations: header ${c.valid ? 'valid' : `refused (${c.why})`}`, () => {
    assert.equal(headerError(c.header) === null, c.valid);
  });
}

for (const c of cases.observations) {
  test(`observations: ${c.valid ? 'valid' : `refused (${c.why})`}`, () => {
    assert.equal(observationError(c.observation) === null, c.valid);
  });
}

test('observations: every fixture observation is valid', () => {
  const lines = readFileSync(new URL('../../fixtures/a-short-day.jsonl', import.meta.url), 'utf8').split('\n').filter(Boolean);
  for (const line of lines.slice(1)) assert.equal(observationError(JSON.parse(line)), null, line);
});

/** A repository with two commits, one with a key pasted into its subject. */
function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'pc-git-'));
  const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', ...args], { stdio: 'ignore' });
  git('init', '-q');
  writeFileSync(join(dir, 'a.txt'), 'a');
  git('add', '.');
  git('commit', '-q', '-m', 'start the plan');
  writeFileSync(join(dir, 'b.txt'), 'b');
  git('add', '.');
  git('commit', '-q', '-m', 'rotate ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx');
  return dir;
}

/** A sensor written on the spot, from its stdout lines. */
function sensor(lines) {
  const dir = mkdtempSync(join(tmpdir(), 'pc-sensor-'));
  const file = join(dir, 'sensor.mjs');
  writeFileSync(file, lines.map((l) => `console.log(${JSON.stringify(JSON.stringify(l))});`).join('\n'));
  return { command: [process.execPath, file], cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('sensor kit: the git-activity example passes', async () => {
  const dir = repo();
  try {
    assert.deepEqual(await checkSensor([process.execPath, GIT_ACTIVITY, '--once', dir]), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('sensor host: a sensor\'s observations are redacted and sealed as sensor:<name>', async () => {
  const dir = repo();
  const store = openStore();
  try {
    const { name, stats } = await runSensor({ command: [process.execPath, GIT_ACTIVITY, '--once', dir], store });
    assert.equal(name, 'git-activity');
    assert.equal(stats.appended, 2);
    assert.equal(stats.redacted, 1);
    const texts = stats.captureIds.map((id) => store.contentText(id));
    assert.ok(texts.some((t) => t.includes('start the plan')));
    assert.ok(!texts.some((t) => t.includes('sk-ant-api03')), 'a key in a commit message was stored');
    const sources = store.db.prepare('SELECT DISTINCT source FROM capture_event').all().map((r) => r.source);
    assert.deepEqual(sources, ['sensor:git-activity']);

    // Everything from one sensor can be revoked at once.
    const { revokedCaptureIds } = store.revoke({ scopeKind: 'source', scopeValue: 'sensor:git-activity' });
    assert.equal(revokedCaptureIds.length, 2);
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('sensor host: observations are dropped, not queued, while capture is held', async () => {
  const s = sensor([{ sensor: 'held', protocol: '1' }, { at: '2026-10-06T09:00:00.000Z', kind: 'activity', app: 'x', state: 'active' }]);
  const store = openStore();
  try {
    const { stats, dropped } = await runSensor({ command: s.command, store, held: () => true });
    assert.equal(dropped, 1);
    assert.equal(stats.appended, 0);
  } finally {
    store.close();
    s.cleanup();
  }
});

test('sensor host: the user\'s exclusions apply to a sensor as to any capture', async () => {
  const s = sensor([
    { sensor: 'bank-watch', protocol: '1' },
    { at: '2026-10-06T09:00:00.000Z', kind: 'screen', app: 'Arc', window: 'Chase — Accounts', text: 'balance 2,310.55' },
  ]);
  const store = openStore();
  try {
    const { stats } = await runSensor({ command: s.command, store, fragments: ['chase'] });
    assert.equal(stats.excluded, 1);
    assert.equal(stats.appended, 0);
  } finally {
    store.close();
    s.cleanup();
  }
});

test('sensor kit: fails a sensor with an invalid observation', async () => {
  const s = sensor([{ sensor: 'leaky', protocol: '1' }, { at: '2026-10-06T09:00:00.000Z', kind: 'keystrokes', text: 'hunter2' }]);
  try {
    const failures = await checkSensor(s.command);
    assert.ok(failures.some((f) => f.includes("cases/observations.json")), failures.join('; '));
  } finally {
    s.cleanup();
  }
});

test('sensor kit: fails a sensor with no valid header', async () => {
  const s = sensor([{ sensor: 'Not A Name', protocol: '1' }]);
  try {
    const failures = await checkSensor(s.command);
    assert.ok(failures.some((f) => f.startsWith('sensor header')), failures.join('; '));
  } finally {
    s.cleanup();
  }
});

test('sensor kit: fails a sensor that emits nothing', async () => {
  const s = sensor([{ sensor: 'silent', protocol: '1' }]);
  try {
    assert.ok((await checkSensor(s.command)).includes('emitted no observations'));
  } finally {
    s.cleanup();
  }
});

test('observations: the dedupe key is derived as the shared vector says', () => {
  for (const v of cases.dedupe_vectors) {
    const store = openStore(':memory:', { masterKey: Buffer.from(v.master_key_hex, 'hex') });
    assert.equal(store.dedupeKeyFor(v.source, v.value), v.dedupe_key);
    store.close();
  }
});

test('sensor host: a restarted sensor adds nothing it already sent, and nothing revoked comes back', async () => {
  const dir = repo();
  const store = openStore();
  const command = [process.execPath, GIT_ACTIVITY, '--once', dir];
  try {
    assert.equal((await runSensor({ command, store })).stats.appended, 2);
    const again = await runSensor({ command, store });
    assert.deepEqual([again.stats.appended, again.stats.duplicates], [0, 2]);

    store.revoke({ scopeKind: 'source', scopeValue: 'sensor:git-activity' });
    const afterRevoke = await runSensor({ command, store });
    assert.equal(afterRevoke.stats.appended, 0, 'a revoked commit was captured again');
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('sensor host: a sensor that ignores being told to stop is killed, not waited on forever', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-stubborn-'));
  const file = join(dir, 'sensor.mjs');
  writeFileSync(file, [
    "console.log(JSON.stringify({ sensor: 'stubborn', protocol: '1' }));",
    "console.log(JSON.stringify({ at: '2026-10-06T09:00:00.000Z', kind: 'activity', app: 'x', state: 'active' }));",
    "process.on('SIGTERM', () => {});",
    'setInterval(() => {}, 1000);',
  ].join('\n'));
  const store = openStore();
  const started = Date.now();
  try {
    const { stats } = await runSensor({ command: [process.execPath, file], store, timeoutMs: 300 });
    assert.equal(stats.appended, 1);
    assert.ok(Date.now() - started < 6000, `took ${Date.now() - started} ms`);
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('sensor pins: a sensor runs only as approved, and not once its script or executable changes', async () => {
  const { computePins, pinError } = await import('../../src/pins.js');
  const s = sensor([{ sensor: 'pinned', protocol: '1' }, { at: '2026-10-06T09:00:00.000Z', kind: 'activity', app: 'x', state: 'active' }]);
  const store = openStore();
  try {
    const pins = computePins(s.command);
    assert.deepEqual(Object.keys(pins).sort(), [...s.command].sort(), 'the executable and the script are both pinned');
    assert.equal((await runSensor({ command: s.command, store, pins })).stats.appended, 1);

    await assert.rejects(runSensor({ command: s.command, store, pins: {} }), /not approved/);
    writeFileSync(s.command[1], "console.log(JSON.stringify({ sensor: 'pinned', protocol: '1' })); /* swapped */");
    assert.match(pinError(s.command, pins), /has changed since it was approved/);
    await assert.rejects(runSensor({ command: s.command, store, pins }), /has changed/);
    assert.throws(() => computePins(['node', s.command[1]]), /absolute path/);
  } finally {
    store.close();
    s.cleanup();
  }
});

test('sensor pins: a directory a sensor watches is data, not pinned', async () => {
  const { computePins } = await import('../../src/pins.js');
  const dir = repo();
  try {
    const pins = computePins([process.execPath, GIT_ACTIVITY, '--once', dir]);
    assert.deepEqual(Object.keys(pins).sort(), [process.execPath, GIT_ACTIVITY].sort());
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
