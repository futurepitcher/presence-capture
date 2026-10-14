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
 * With the app running and capturing for 20 minutes or more, it:
 *  1. gives itself a grant for the run (pcap grant add), notes a control capture from before the
 *     window to be forgotten, and asks you to show a marker on screen (and say it, if the app hears
 *     the microphone). It waits until the marker is captured and readable through pcap-mcp;
 *  2. snapshots the sealed bytes (wrapped keys, sealed text and payloads, projection outputs) of
 *     every capture in the last 15 minutes. These are raw bytes, so no key is needed;
 *  3. pins the store's write-ahead log with a read transaction of its own, and asks you to choose
 *     Forget the Last 15 Minutes… in the menu;
 *  4. while pinned, checks:
 *     - the revocation is in force (pcap-mcp no longer finds the marker);
 *     - it revoked exactly what it should: every capture stamped in the range, and what was derived
 *       from them, worked out from the store's metadata alone;
 *     - its erasure receipt and per-projection receipts exist, and the erasure is pending
 *       (completed_at is NULL): it may still be in the log;
 *  5. lets go of the pin, and within 30 seconds (the app's tick is 5) checks:
 *     - the erasure completed;
 *     - none of the snapshotted bytes is left in any file under the store's folder;
 *     - nothing stamped inside the window is stored unrevoked (H2, H6);
 *     - the control capture is still readable.
 *
 * Exits 1 on any failure, 2 if it can't run. It revokes its own grant at the end. No dependencies.
 */

import { spawn, execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { filesUnder, sealedArtifacts } from '../packages/schema/conformance/store/inspect.js';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
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
const ask = async (question) => {
  const io = createInterface({ input: process.stdin, output: process.stdout });
  await io.question(`\n${question}\n[press Return] `);
  io.close();
};

/** A read of the store's metadata, on a connection of its own, closed after. */
const query = (sql, ...params) => {
  const db = new DatabaseSync(store, { readOnly: true });
  try {
    return db.prepare(sql).all(...params);
  } finally {
    db.close();
  }
};

/** pcap-mcp, as an agent starts it: the MCP lifecycle, then tools. */
function mcp(grantId) {
  const server = spawn(args.mcp, ['--grant', grantId, '--store', store, ...keyArgs], { stdio: ['pipe', 'pipe', 'inherit'] });
  const waiting = new Map();
  let buffer = '';
  server.stdout.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      waiting.get(message.id)?.(message);
      waiting.delete(message.id);
    }
  });
  let next = 1;
  const rpc = (method, params) => new Promise((done, failed) => {
    const id = next++;
    const timer = setTimeout(() => failed(new Error(`${method} got no answer`)), 30_000);
    waiting.set(id, (message) => { clearTimeout(timer); done(message); });
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
    close: () => server.stdin.end(),
  };
}
const ids = (envelopes) => envelopes.map((e) => e.presence_capture_untrusted.provenance.capture_id);
const contains = (haystack, needle) => needle.length > 0 && haystack.indexOf(needle) !== -1;

let grantId;
let client;
let pin;
try {
  // 1. A grant for the run, a control from before the window, and the marker, captured.
  grantId = execFileSync(pcap, ['grant', 'add', 'live-forget-check', '--days', '1', '--store', store, ...keyArgs], { encoding: 'utf8' }).split('\n')[0].trim();
  if (!grantId.startsWith('grn_')) throw new Error(`pcap didn't issue a grant: ${grantId}`);
  client = mcp(grantId);
  await client.start();
  process.stdout.write(`live forget check: ${store}\n`);

  const now = Date.now();
  const control = ids(await client.call('timeline', { from: new Date(now - 60 * 60_000).toISOString(), to: new Date(now - 20 * 60_000).toISOString(), limit: 1 }))[0];
  if (!control) throw new Error('no capture from 20 to 60 minutes ago to keep as the control: let the app capture for 20 minutes first');
  ok(`control capture from before the window: ${control}`);

  const marker = `pcforget${randomBytes(4).toString('hex')}`;
  await ask(`Show this word on screen, where Presence Capture reads it (a TextEdit window, say), and say it aloud if it hears the microphone:\n\n    ${marker}\n\nThen leave it on screen for a few seconds.`);
  let markers = [];
  for (let i = 0; i < 36 && markers.length === 0; i++) {
    markers = ids(await client.call('search', { query: marker, limit: 10 }));
    if (markers.length === 0) await sleep(5_000);
  }
  if (markers.length === 0) throw new Error(`the marker wasn't captured within 3 minutes: is the app capturing, with Screen Recording allowed?`);
  ok(`marker captured and readable: ${markers.join(', ')}`);

  // 2. The sealed bytes of everything in the window, before Forget.
  const windowStart = new Date(Date.now() - 15 * 60_000).toISOString();
  const inWindow = query('SELECT capture_id FROM capture_event WHERE captured_at >= ? AND capture_id NOT IN (SELECT capture_id FROM revoked_capture)', windowStart)
    .map((r) => r.capture_id);
  const secrets = sealedArtifacts(store, folder, inWindow);
  ok(`${secrets.length} sealed artifacts snapshotted, from ${inWindow.length} captures in the last 15 minutes`);
  const before = query('SELECT COALESCE(MAX(sequence), 0) AS s FROM revocation')[0].s;

  // 3. The log pinned, and Forget chosen.
  pin = new DatabaseSync(store, { readOnly: true });
  pin.exec('BEGIN');
  pin.prepare('SELECT COUNT(*) FROM capture_event').get();
  await ask('The store\'s log is pinned. Now choose "Forget the Last 15 Minutes…" in the Presence Capture menu, confirm it, and dismiss what it says.');

  // 4. While pinned.
  process.stdout.write('\nWhile the log is pinned:\n');
  const revocation = query('SELECT revocation_id, scope_kind, scope_value FROM revocation WHERE sequence > ? ORDER BY sequence DESC LIMIT 1', before)[0];
  if (!revocation) throw new Error('no new revocation: was Forget chosen and confirmed?');
  if (revocation.scope_kind !== 'time_range') fail(`the revocation's scope is ${revocation.scope_kind}, not a time range`);
  const [from, to] = revocation.scope_value.split('/');
  if (ids(await client.call('search', { query: marker, limit: 10 })).length === 0) ok('the marker is no longer served');
  else fail('pcap-mcp still serves the marker after Forget');

  // Expected: every capture stamped in the range, and what was derived from them, from metadata.
  const expected = query(`
    WITH RECURSIVE reached(capture_id) AS (
      SELECT capture_id FROM capture_event WHERE captured_at >= ? AND captured_at <= ?
      UNION SELECT e.capture_id FROM capture_event e JOIN reached r ON e.derived_from = r.capture_id)
    SELECT capture_id FROM reached`, from, to).map((r) => r.capture_id);
  const revoked = new Set(query('SELECT capture_id FROM revoked_capture WHERE revocation_id = ?', revocation.revocation_id).map((r) => r.capture_id));
  const earlier = new Set(query('SELECT capture_id FROM revoked_capture WHERE revocation_id <> ?', revocation.revocation_id).map((r) => r.capture_id));
  const missing = expected.filter((id) => !revoked.has(id) && !earlier.has(id));
  if (missing.length === 0) ok(`the revocation reached all ${expected.length} captures in its range and derived from them`);
  else fail(`${missing.length} captures in the range weren't revoked: ${missing.slice(0, 5).join(', ')}`);
  const markersRevoked = markers.every((id) => revoked.has(id));
  if (markersRevoked) ok('the marker captures are among them');
  else fail('a marker capture wasn\'t revoked');

  const receipt = query('SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?', revocation.revocation_id)[0];
  if (!receipt) fail('no erasure receipt');
  else if (receipt.completed_at === null) ok('the erasure receipt exists, pending while the log is pinned');
  else fail('the erasure was marked complete while the log was pinned');
  const projections = query('SELECT projection_name FROM projection').map((r) => r.projection_name);
  const receipts = new Set(query('SELECT projection_name FROM projection_revocation WHERE revocation_id = ?', revocation.revocation_id).map((r) => r.projection_name));
  if (projections.every((p) => receipts.has(p))) ok(`a receipt for each of ${projections.length} projections`);
  else fail('a projection has no receipt for the revocation');

  // 5. The pin let go; within 30 s, the erasure completes and nothing survives.
  pin.exec('COMMIT');
  pin.close();
  pin = undefined;
  process.stdout.write('\nAfter the log is let go:\n');
  let completed = null;
  for (let i = 0; i < 30 && !completed; i++) {
    completed = query('SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?', revocation.revocation_id)[0]?.completed_at ?? null;
    if (!completed) await sleep(1_000);
  }
  if (completed) ok(`the erasure completed at ${completed}`);
  else fail('the erasure didn\'t complete within 30 seconds');

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
  if (survivors === 0) ok(`none of the ${secrets.length} sealed artifacts is left in any file under the store's folder`);
  else if (survivors > 5) fail(`…and ${survivors - 5} more`);

  const stored = query('SELECT COUNT(*) AS n FROM capture_event WHERE captured_at >= ? AND captured_at <= ? AND capture_id NOT IN (SELECT capture_id FROM revoked_capture)', from, to)[0].n;
  if (stored === 0) ok('nothing stamped inside the window is stored unrevoked');
  else fail(`${stored} captures stamped inside the window are stored unrevoked`);

  const controlRow = query('SELECT captured_at FROM capture_event WHERE capture_id = ?', control)[0];
  const around = ids(await client.call('timeline', { from: new Date(Date.parse(controlRow.captured_at) - 1_000).toISOString(), to: new Date(Date.parse(controlRow.captured_at) + 1_000).toISOString(), limit: 50 }));
  if (around.includes(control)) ok('the control capture is still readable');
  else fail('the control capture is no longer readable');
} catch (err) {
  process.stderr.write(`live-forget-check: ${err.message}\n`);
  process.exitCode = 2;
} finally {
  if (pin) {
    try { pin.exec('ROLLBACK'); pin.close(); } catch { /* already closed */ }
  }
  client?.close();
  if (grantId?.startsWith('grn_')) {
    try { execFileSync(pcap, ['grant', 'revoke', grantId, '--store', store, ...keyArgs], { stdio: 'ignore' }); } catch { /* reported by pcap */ }
  }
}
if (process.exitCode !== 2) {
  process.stdout.write(failures.length ? `\nFAIL: ${failures.length} check(s) failed\n` : '\nPASS\n');
  process.exitCode = failures.length ? 1 : 0;
}
