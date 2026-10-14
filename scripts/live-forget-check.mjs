#!/usr/bin/env node
/**
 * The live forget check (release criterion 5): Forget, on a real Mac, with the app capturing,
 * proven by looking at the disk the way someone holding a copy of the store would. It reuses the
 * conformance suite's artifact scan (packages/schema/conformance/store/inspect.js). Sealed content
 * never shows its words, so it looks for the exact sealed bytes, not for text.
 *
 *   node scripts/live-forget-check.mjs \
 *     --store "$HOME/Library/Application Support/Presence Capture/store.sqlite" \
 *     --mcp "/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp"
 *
 * With the app running and capturing for 20 minutes or more, and Hear the Microphone on, it:
 *  1. gives itself a grant for the run (pcap grant add), notes a control capture from before the
 *     window to be forgotten, and asks you to put two words on screen and say them aloud. It waits
 *     until both are captured and readable through pcap-mcp: on screen (screen_text) and heard by
 *     the microphone (an audio_transcript from input);
 *  2. asks you to Pause, and waits until nothing new is captured for two of the app's ticks; then
 *     snapshots, capture by capture, the sealed bytes (wrapped keys, sealed text and payloads,
 *     projection outputs) of everything from the last 20 minutes. These are raw bytes, so no key
 *     is needed. Every capture Forget then revokes must have been snapshotted;
 *  3. pins the store's write-ahead log with a read transaction of its own, and asks you to choose
 *     Forget the Last 15 Minutes… in the menu;
 *  4. while pinned, checks:
 *     - the revocation is in force (pcap-mcp no longer finds the words);
 *     - it revoked exactly what it should, no more and no less: every capture stamped in its range,
 *       and what was derived from them, less what earlier revocations had taken, worked out from
 *       the store's metadata alone;
 *     - its erasure receipt and per-projection receipts exist, and the erasure is pending
 *       (completed_at is NULL): it may still be in the log;
 *  5. lets go of the pin, and within 10 seconds (two of the app's 5-second ticks) checks:
 *     - the erasure completed;
 *     - none of the snapshotted bytes of the captures it revoked is left in any file under the
 *       store's folder (the words' captures must be among them);
 *     - nothing stamped inside the window is stored unrevoked (H2, H6);
 *     - the control capture is still readable;
 *     and reminds you to Resume.
 *
 * Exits 0 on PASS, 1 on any failed check, 2 if it can't run (or can't revoke its own grant, which
 * it then names), and 3 if it's INCOMPLETE: the words were captured from the screen but never heard
 * from the microphone. It revokes its own grant however it ends, Ctrl-C included. No dependencies.
 */

import { spawn, execFileSync } from 'node:child_process';
import { randomInt } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { DatabaseSync } from 'node:sqlite';
import { filesUnder, sealedArtifacts } from '../packages/schema/conformance/store/inspect.js';

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, word, i, all) => {
  if (word.startsWith('--')) pairs.push([word.slice(2), all[i + 1]]);
  return pairs;
}, []));
if (!args.store || !args.mcp) {
  process.stderr.write('usage: live-forget-check.mjs --store <store.sqlite> --mcp <pcap-mcp> [--pcap <pcap>] [--master-key-file <file>]\n');
  process.exit(2);
}
const store = resolve(args.store);
// For a scratch store only (the app's own store's key is in the Keychain, which pcap and pcap-mcp read).
const keyArgs = args['master-key-file'] ? ['--master-key-file', resolve(args['master-key-file'])] : [];
const folder = dirname(store);
const pcap = args.pcap ?? join(dirname(args.mcp), 'pcap');
const failures = [];
const fail = (why) => {
  failures.push(why);
  process.stdout.write(`  ✗ ${why}\n`);
};
const ok = (what) => process.stdout.write(`  ✓ ${what}\n`);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
/** A question, answered with Return; Ctrl-C ends the run (and cleans up). */
const ask = (question) => new Promise((answered, failed) => {
  const io = createInterface({ input: process.stdin, output: process.stdout });
  io.on('SIGINT', () => {
    io.close();
    failed(new Interrupted());
  });
  io.question(`\n${question}\n[press Return] `).then(() => {
    io.close();
    answered();
  }, failed);
});
class Interrupted extends Error {
  constructor() { super('interrupted'); }
}

/** A read of the store's metadata, on a connection of its own, closed after. */
const query = (sql, ...params) => {
  const db = new DatabaseSync(store, { readOnly: true });
  try {
    return db.prepare(sql).all(...params);
  } finally {
    db.close();
  }
};

/** pcap-mcp, as an agent starts it: the MCP lifecycle, then tools. Anything going wrong with it fails the call waiting on it. */
function mcp(grantId) {
  const server = spawn(args.mcp, ['--grant', grantId, '--store', store, ...keyArgs], { stdio: ['pipe', 'pipe', 'inherit'] });
  const waiting = new Map();
  let gone = null;
  let exited = false;
  const end = (why) => {
    gone ??= why;
    for (const call of waiting.values()) call.failed(new Error(gone));
    waiting.clear();
  };
  server.on('error', (err) => end(`pcap-mcp couldn't run: ${err.message}`));
  server.on('exit', (code, signal) => {
    exited = true;
    end(`pcap-mcp exited (${signal ?? code})`);
  });
  server.stdin.on('error', (err) => end(`pcap-mcp's input closed: ${err.message}`));
  let buffer = '';
  server.stdout.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return end('pcap-mcp wrote a line that isn\'t JSON');
      }
      const call = waiting.get(message.id);
      waiting.delete(message.id);
      call?.done(message);
    }
  });
  let next = 1;
  const rpc = (method, params) => new Promise((done, failed) => {
    if (gone) return failed(new Error(gone));
    const id = next++;
    const timer = setTimeout(() => {
      waiting.delete(id);
      failed(new Error(`${method} got no answer`));
    }, 30_000);
    waiting.set(id, { done: (message) => { clearTimeout(timer); done(message); }, failed: (err) => { clearTimeout(timer); failed(err); } });
    server.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
  return {
    async start() {
      const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'live-forget-check', version: '1' } });
      if (init.error) throw new Error(`pcap-mcp refused to start: ${JSON.stringify(init.error)}`);
      server.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
    },
    async call(name, toolArgs) {
      const answer = await rpc('tools/call', { name, arguments: toolArgs });
      if (answer.error || answer.result?.isError) throw new Error(`${name} failed: ${JSON.stringify(answer.error ?? answer.result)}`);
      const value = JSON.parse(answer.result.content[0].text);
      return Array.isArray(value) ? value : value.envelopes;
    },
    /** Ends it, and waits until it has (killed after 5 s). */
    async close() {
      if (exited) return;
      const ended = new Promise((done) => server.once('exit', done));
      server.stdin.end();
      const timer = setTimeout(() => server.kill(), 5_000);
      await ended;
      clearTimeout(timer);
    },
  };
}
const provenance = (e) => e.presence_capture_untrusted.provenance;
const ids = (envelopes) => envelopes.map((e) => provenance(e).capture_id);
const contains = (haystack, needle) => needle.length > 0 && haystack.indexOf(needle) !== -1;

// Two words, easy to say and to read, and rare enough together to be this run's.
const WORDS = ['marmalade', 'zeppelin', 'porcupine', 'tangerine', 'harmonica', 'lighthouse', 'avalanche', 'saxophone',
  'pelican', 'volcano', 'kangaroo', 'cinnamon', 'hurricane', 'trombone', 'pineapple', 'walrus', 'telescope',
  'jellyfish', 'umbrella', 'dinosaur', 'penguin', 'raspberry', 'tornado', 'accordion'];

let grantId;
let client;
let pin;
let cleanedUp;
let grantLeft = false;

/** Once, however the run ends: the pin let go, pcap-mcp ended, and the run's grant revoked, checked. */
function cleanup() {
  cleanedUp ??= (async () => {
    if (pin) {
      try { pin.exec('ROLLBACK'); } catch { /* not in a transaction */ }
      try { pin.close(); } catch { /* already closed */ }
      pin = undefined;
    }
    await client?.close().catch(() => {});
    if (!grantId) return;
    let revoked = false;
    for (let i = 0; i < 3 && !revoked; i++) {
      try { execFileSync(pcap, ['grant', 'revoke', grantId, '--store', store, ...keyArgs], { stdio: 'ignore' }); } catch { /* checked below */ }
      try { revoked = query('SELECT revoked_at FROM grant_record WHERE grant_id = ?', grantId)[0]?.revoked_at != null; } catch { /* checked again */ }
      if (!revoked) await sleep(1_000);
    }
    if (!revoked) {
      grantLeft = true;
      process.stderr.write(`live-forget-check: its grant ${grantId} is still active. Revoke it:  "${pcap}" grant revoke ${grantId}\n`);
    }
  })();
  return cleanedUp;
}
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    process.stderr.write(`\nlive-forget-check: ${signal === 'SIGINT' ? 'interrupted' : 'stopped'}; cleaning up\n`);
    cleanup().finally(() => process.exit(grantLeft ? 2 : 130));
  });
}

let incomplete = false;
try {
  // 1. A grant for the run, a control from before the window, and the words, captured.
  grantId = execFileSync(pcap, ['grant', 'add', 'live-forget-check', '--days', '1', '--store', store, ...keyArgs], { encoding: 'utf8' }).split('\n')[0].trim();
  if (!grantId.startsWith('grn_')) throw new Error(`pcap didn't issue a grant: ${grantId}`);
  client = mcp(grantId);
  await client.start();
  process.stdout.write(`live forget check: ${store}\n`);

  const now = Date.now();
  const control = ids(await client.call('timeline', { from: new Date(now - 60 * 60_000).toISOString(), to: new Date(now - 20 * 60_000).toISOString(), limit: 1 }))[0];
  if (!control) throw new Error('no capture from 20 to 60 minutes ago to keep as the control: let the app capture for 20 minutes first');
  ok(`control capture from before the window: ${control}`);

  const first = WORDS[randomInt(WORDS.length)];
  let second;
  do second = WORDS[randomInt(WORDS.length)]; while (second === first);
  const phrase = `${first} ${second}`;
  const askedAt = Date.now() - 5_000;
  await ask(`Turn on Hear the Microphone in the Presence Capture menu if it's off. Then put these two words on screen, where the app\nreads them (a TextEdit window, say), and say them aloud, two or three times:\n\n    ${phrase}\n\nLeave them on screen for a few seconds.`);
  // Captured since asked, with both words in it: from the screen, and heard from the microphone.
  const said = (e) => {
    const { captured_at: at, capture_type: type, source_app: app } = provenance(e);
    const text = String(e.presence_capture_untrusted.content ?? '').toLowerCase();
    return Date.parse(at) >= askedAt && text.includes(first) && text.includes(second) ? { type, app } : null;
  };
  let seen = [];
  let screen = [];
  let spoken = [];
  for (let i = 0; i < 36 && (screen.length === 0 || spoken.length === 0); i++) {
    seen = (await client.call('search', { query: phrase, limit: 50 })).filter((e) => said(e));
    screen = seen.filter((e) => said(e).type === 'screen_text');
    spoken = seen.filter((e) => said(e).type === 'audio_transcript' && said(e).app === 'input');
    if (screen.length === 0 || spoken.length === 0) await sleep(5_000);
  }
  if (screen.length === 0) throw new Error('the words weren\'t captured from the screen within 3 minutes: is the app capturing, with Screen Recording allowed?');
  ok(`on screen, captured and readable: ${ids(screen).join(', ')}`);
  if (spoken.length > 0) ok(`said aloud, heard and readable: ${ids(spoken).join(', ')}`);
  else {
    incomplete = true;
    process.stdout.write('  ! the words weren\'t heard from the microphone within 3 minutes (is Hear the Microphone on?): the run checks the screen alone, and is INCOMPLETE\n');
  }
  const markers = ids(seen);

  // 2. Paused, so nothing new is captured between the snapshot and Forget: what Forget revokes must
  // all have been snapshotted, or it can't be looked for on disk.
  await ask('Now choose Pause in the Presence Capture menu, so nothing new is captured while the store is checked.');
  const latest = () => query('SELECT COALESCE(MAX(sequence), 0) AS s FROM capture_event')[0].s;
  let last = latest();
  let quietSince = Date.now();
  for (const started = Date.now(); Date.now() - quietSince < 12_000;) {
    if (Date.now() - started > 90_000) throw new Error('captures kept arriving for 90 seconds: is Presence Capture paused?');
    await sleep(1_000);
    const now = latest();
    if (now !== last) [last, quietSince] = [now, Date.now()];
  }
  ok('paused: nothing new captured for 12 seconds');

  // The sealed bytes, capture by capture, of everything from the last 20 minutes: wider than any
  // 15 minutes Forget can take from here on.
  const snapshotFrom = new Date(Date.now() - 20 * 60_000).toISOString();
  const snapshotted = query('SELECT capture_id FROM capture_event WHERE captured_at >= ? AND capture_id NOT IN (SELECT capture_id FROM revoked_capture)', snapshotFrom)
    .map((r) => r.capture_id);
  const artifacts = new Map(snapshotted.map((id) => [id, sealedArtifacts(store, folder, [id])]));
  const bare = markers.filter((id) => !(artifacts.get(id)?.length > 0));
  if (bare.length === 0) ok(`sealed bytes snapshotted from ${snapshotted.length} captures, the words' among them`);
  else fail(`no sealed bytes were snapshotted for ${bare.join(', ')}`);
  const before = query('SELECT COALESCE(MAX(sequence), 0) AS s FROM revocation')[0].s;

  // 3. The log pinned, and Forget chosen.
  pin = new DatabaseSync(store, { readOnly: true });
  pin.exec('BEGIN');
  pin.prepare('SELECT COUNT(*) FROM capture_event').get();
  await ask('The store\'s log is pinned. Now choose "Forget the Last 15 Minutes…" in the Presence Capture menu, confirm it, and dismiss what it says.');

  // 4. While pinned.
  process.stdout.write('\nWhile the log is pinned:\n');
  const forgets = query("SELECT revocation_id, sequence, scope_kind, scope_value, reason FROM revocation WHERE sequence > ? AND reason LIKE 'forget %' ORDER BY sequence", before);
  if (forgets.length === 0) throw new Error('no new Forget: was it chosen and confirmed?');
  if (forgets.length > 1) fail(`${forgets.length} Forgets were made: choose it once`);
  const revocation = forgets[0];
  if (revocation.scope_kind !== 'time_range') throw new Error(`the Forget's scope is ${revocation.scope_kind}, not a time range`);
  const [from, to] = revocation.scope_value.split('/');
  const stillServed = (await client.call('search', { query: phrase, limit: 50 })).filter((e) => markers.includes(provenance(e).capture_id));
  if (stillServed.length === 0) ok('the words are no longer served');
  else fail('pcap-mcp still serves the words after Forget');

  // Expected: every capture stamped in the range, and what was derived from them, less what an
  // earlier revocation had taken; from metadata. The revocation must be exactly that.
  const expected = new Set(query(`
    WITH RECURSIVE reached(capture_id) AS (
      SELECT capture_id FROM capture_event WHERE captured_at >= ? AND captured_at <= ?
      UNION SELECT e.capture_id FROM capture_event e JOIN reached r ON e.derived_from = r.capture_id)
    SELECT capture_id FROM reached WHERE capture_id NOT IN (
      SELECT rc.capture_id FROM revoked_capture rc JOIN revocation v ON v.revocation_id = rc.revocation_id WHERE v.sequence < ?)`,
  from, to, revocation.sequence).map((r) => r.capture_id));
  const revoked = new Set(query('SELECT capture_id FROM revoked_capture WHERE revocation_id = ?', revocation.revocation_id).map((r) => r.capture_id));
  const missing = [...expected].filter((id) => !revoked.has(id));
  const extra = [...revoked].filter((id) => !expected.has(id));
  if (missing.length === 0 && extra.length === 0) ok(`it revoked exactly the ${expected.size} captures in its range and derived from them`);
  if (missing.length > 0) fail(`${missing.length} captures in its range weren't revoked: ${missing.slice(0, 5).join(', ')}`);
  if (extra.length > 0) fail(`${extra.length} captures outside its range were revoked: ${extra.slice(0, 5).join(', ')}`);
  if (markers.every((id) => revoked.has(id))) ok('the words\' captures are among them');
  else fail('a capture of the words wasn\'t revoked');

  const receipt = query('SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?', revocation.revocation_id)[0];
  if (!receipt) fail('no erasure receipt');
  else if (receipt.completed_at === null) ok('the erasure receipt exists, pending while the log is pinned');
  else fail('the erasure was marked complete while the log was pinned');
  const projections = query('SELECT projection_name FROM projection').map((r) => r.projection_name);
  const receipts = new Set(query('SELECT projection_name FROM projection_revocation WHERE revocation_id = ?', revocation.revocation_id).map((r) => r.projection_name));
  if (projections.every((p) => receipts.has(p))) ok(`a receipt for each of ${projections.length} projections`);
  else fail('a projection has no receipt for the revocation');

  // 5. The pin let go; within two ticks, the erasure completes and nothing it revoked survives.
  pin.exec('COMMIT');
  pin.close();
  pin = undefined;
  process.stdout.write('\nAfter the log is let go:\n');
  let completed = null;
  for (let i = 0; i < 10 && !completed; i++) {
    completed = query('SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?', revocation.revocation_id)[0]?.completed_at ?? null;
    if (!completed) await sleep(1_000);
  }
  if (completed) ok(`the erasure completed at ${completed}`);
  else fail('the erasure didn\'t complete within 10 seconds');

  const unsnapshotted = [...revoked].filter((id) => !artifacts.has(id));
  if (unsnapshotted.length > 0) fail(`${unsnapshotted.length} captures it revoked were made after the snapshot, so they can't be looked for on disk (was it paused?): ${unsnapshotted.slice(0, 5).join(', ')}`);
  const secrets = [...revoked].flatMap((id) => artifacts.get(id) ?? []);
  if (secrets.length === 0) fail('none of the captures it revoked had sealed bytes snapshotted: nothing to look for');
  let survivors = 0;
  // Regular files only: a socket or pipe in the folder isn't the store's, and reading one blocks.
  for (const file of filesUnder(folder).filter((f) => statSync(f).isFile())) {
    const bytes = readFileSync(file);
    for (const [label, secret] of secrets) {
      if (contains(bytes, secret)) {
        survivors++;
        if (survivors <= 5) fail(`${label} survived in ${file.slice(folder.length + 1)}`);
      }
    }
  }
  if (secrets.length > 0 && survivors === 0) ok(`none of the ${secrets.length} sealed artifacts it revoked is left in any file under the store's folder`);
  else if (survivors > 5) fail(`…and ${survivors - 5} more`);

  const stored = query('SELECT COUNT(*) AS n FROM capture_event WHERE captured_at >= ? AND captured_at <= ? AND capture_id NOT IN (SELECT capture_id FROM revoked_capture)', from, to)[0].n;
  if (stored === 0) ok('nothing stamped inside the window is stored unrevoked');
  else fail(`${stored} captures stamped inside the window are stored unrevoked`);

  const controlRow = query('SELECT captured_at FROM capture_event WHERE capture_id = ?', control)[0];
  const around = ids(await client.call('timeline', { from: new Date(Date.parse(controlRow.captured_at) - 1_000).toISOString(), to: new Date(Date.parse(controlRow.captured_at) + 1_000).toISOString(), limit: 50 }));
  if (around.includes(control)) ok('the control capture is still readable');
  else fail('the control capture is no longer readable');
  process.stdout.write('\nChoose Resume in the Presence Capture menu to capture again.\n');
} catch (err) {
  process.stderr.write(`live-forget-check: ${err instanceof Interrupted ? 'interrupted' : err.message}\n`);
  process.exitCode = err instanceof Interrupted ? 130 : 2;
} finally {
  await cleanup();
}
if (grantLeft) process.exitCode = 2;
else if (process.exitCode === undefined || process.exitCode === 0) {
  const verdict = failures.length ? `FAIL: ${failures.length} check(s) failed` : incomplete ? 'INCOMPLETE: nothing was heard from the microphone' : 'PASS';
  process.stdout.write(`\n${verdict}\n`);
  process.exitCode = failures.length ? 1 : incomplete ? 3 : 0;
}
