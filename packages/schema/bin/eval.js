#!/usr/bin/env node
/**
 * pcap-eval: how well, and how fast, an MCP server recalls (ADR 0008).
 *
 *   node packages/schema/bin/eval.js [--server <command>] [--fixture eval/fixtures/three-days.json]
 *        [--days 30] [--per-day 600] [--embed <command>] [--json <file>] [--no-gate]
 *
 * It seeds a store with the fixture's captures (each with the id its questions
 * name) and, with --days, that many days of ordinary filler around them
 * (eval/filler.js, deterministic). It issues a grant, runs `--embed` over the
 * store if given (a command that projects embeddings into it, given --store
 * and --master-key-file: how a candidate model for search by meaning is
 * measured, ADR 0008), starts the server as an MCP client would, and asks
 * every question through `search`.
 *
 * It reports recall@1, recall@5 and MRR (over the first ten results), for all
 * questions and for keyword and paraphrase questions apart, from a first pass
 * over a quiet store, so the scores are the same every run. Then it times
 * every tool twice: quiet, and again while eval/writer.js appends beside the
 * server (as the daemon does while an agent reads), with the calls a writer's
 * batch apart, so each one indexes new captures and meets a write. It reports
 * p50 and p95 for each, after a first call that builds the server's memory
 * (cold start, reported on its own). It exits 1 below the targets the release
 * plan sets: recall@5 at least 0.80, search p95 under 300 ms while writing.
 * --no-gate only reports. A run that can't finish (a server that exits, stops
 * answering, or answers with an error) exits 2, never 0.
 *
 * `--server` and `--embed` are one executable path, or a JSON array for a
 * command with arguments, as the conformance suites take them. Unset,
 * --server is the reference (packages/mcp/src/stdio.js).
 *
 * No dependencies.
 */

import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { commandFrom } from '../conformance/driver-client.js';
import { eachLine, jsonLine } from '../src/lines.js';
import { openStore } from '../src/store.js';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const TARGET = { recallAt5: 0.8, searchP95Ms: 300 };
const PROTOCOL_VERSION = '2025-06-18';
/** How long a call may take before the run fails, and a server that won't exit is killed. */
const REQUEST_TIMEOUT_MS = 60_000;
const EXIT_TIMEOUT_MS = 10_000;
/** The writer's batch interval (eval/writer.js): the loaded pass waits this long between calls. */
const PACE_MS = 250;
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function args() {
  const out = { fixture: join(ROOT, 'eval/fixtures/three-days.json'), days: 0, perDay: 600, gate: true };
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const [name, value] = [argv[i], argv[i + 1]];
    if (name === '--no-gate') { out.gate = false; continue; }
    if (!name.startsWith('--') || value === undefined) throw new Error(`unexpected argument: ${name}`);
    i += 1;
    if (name === '--server') out.server = commandFrom(value);
    else if (name === '--embed') out.embed = commandFrom(value);
    else if (name === '--fixture') out.fixture = resolve(value);
    else if (name === '--days') out.days = Number(value);
    else if (name === '--per-day') out.perDay = Number(value);
    else if (name === '--json') out.json = resolve(value);
    else throw new Error(`unknown option: ${name}`);
  }
  out.server ??= [process.execPath, join(ROOT, 'packages/mcp/src/stdio.js')];
  return out;
}

const percentile = (values, p) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
};

/**
 * An MCP server over stdio, as a client starts one. Every request settles: with
 * its answer, or failing when the server can't start, exits, closes its
 * output, or takes longer than REQUEST_TIMEOUT_MS.
 */
function startServer(command, { path, grantId, keyFile }) {
  const server = spawn(command[0], [...command.slice(1), '--store', path, '--grant', grantId, '--master-key-file', keyFile], {
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const waiting = new Map();
  let gone = null;
  const end = (why) => {
    gone ??= why;
    for (const pending of waiting.values()) pending.fail(new Error(gone));
    waiting.clear();
  };
  server.once('error', (err) => end(`the server couldn't run: ${err.message}`));
  server.once('close', (code, signal) => end(`the server exited (${signal ?? code})`));
  server.stdin.on('error', (err) => end(`the server's input closed: ${err.message}`));
  eachLine(server.stdout, (line) => {
    if (line.trim() === '') return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return end('the server wrote a line that isn\'t JSON');
    }
    if (message === null || typeof message !== 'object' || Array.isArray(message)) {
      return end('the server wrote a line that isn\'t a JSON-RPC message');
    }
    const pending = waiting.get(message.id);
    waiting.delete(message.id);
    pending?.done(message);
  });
  let nextId = 1;
  const rpc = (method, params) => new Promise((done, fail) => {
    if (gone) return fail(new Error(gone));
    const id = nextId++;
    const timer = setTimeout(() => {
      waiting.delete(id);
      fail(new Error(`${method} got no answer in ${REQUEST_TIMEOUT_MS / 1000} s`));
    }, REQUEST_TIMEOUT_MS);
    waiting.set(id, {
      done: (message) => { clearTimeout(timer); done(message); },
      fail: (err) => { clearTimeout(timer); fail(err); },
    });
    server.stdin.write(jsonLine({ jsonrpc: '2.0', id, method, params }));
  });
  /** A notification: no id, no answer. */
  const notify = (method, params) => {
    if (!gone) server.stdin.write(jsonLine({ jsonrpc: '2.0', method, ...(params ? { params } : {}) }));
  };
  /**
   * The MCP lifecycle, as a client runs it: initialize, check the server agreed
   * to this protocol version and offers tools, then say so with
   * notifications/initialized before any other request.
   */
  const initialize = async () => {
    const response = await rpc('initialize', { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: 'pcap-eval', version: '1' } });
    if (response.error) throw new Error(`initialize failed: ${JSON.stringify(response.error)}`);
    const agreed = response.result?.protocolVersion;
    if (agreed !== PROTOCOL_VERSION) throw new Error(`the server answered protocol ${JSON.stringify(agreed)}; this eval speaks ${PROTOCOL_VERSION}`);
    if (!response.result?.capabilities?.tools) throw new Error('the server offers no tools');
    notify('notifications/initialized');
  };
  /** A tool's answer and how long it took, in milliseconds. */
  const call = async (name, args) => {
    const started = process.hrtime.bigint();
    const response = await rpc('tools/call', { name, arguments: args });
    const ms = Number(process.hrtime.bigint() - started) / 1e6;
    if (response.error || response.result?.isError) throw new Error(`${name} failed: ${JSON.stringify(response.error ?? response.result)}`);
    return { answer: JSON.parse(response.result.content[0].text), ms };
  };
  const close = async () => {
    server.stdin.end();
    if (server.exitCode !== null || server.signalCode !== null) return;
    const killer = setTimeout(() => server.kill('SIGKILL'), EXIT_TIMEOUT_MS);
    await new Promise((done) => server.once('close', done));
    clearTimeout(killer);
  };
  return { initialize, call, close };
}

/**
 * eval/writer.js against the store, started once its first batch is in.
 * `stop` resolves to how many captures it wrote, and fails if it wrote none or
 * exited on its own.
 */
async function startWriter({ path, keyFile }) {
  const writer = spawn(process.execPath, [join(ROOT, 'eval/writer.js'), path, keyFile], { stdio: ['pipe', 'pipe', 'inherit'] });
  const said = [];
  let heard = () => {};
  eachLine(writer.stdout, (line) => {
    try {
      const message = JSON.parse(line);
      if (message !== null && typeof message === 'object') said.push(message);
    } catch {
      return;
    }
    heard();
  });
  const closed = new Promise((done) => writer.once('close', (code, signal) => done(signal ?? code)));
  const exited = closed.then((how) => { throw new Error(`the writer exited (${how})`); });
  exited.catch(() => {});
  await Promise.race([new Promise((done) => { heard = done; }), exited]);
  return {
    stop: async () => {
      writer.stdin.end();
      const how = await closed;
      const written = said.find((m) => Number.isInteger(m.written))?.written ?? 0;
      if (how !== 0 || written === 0) throw new Error(`the writer failed (${how}), having written ${written}`);
      return written;
    },
  };
}

const captureIds = (envelopes) => envelopes.map((e) => e.presence_capture_untrusted.provenance.capture_id);

async function main() {
  const options = args();
  const fixture = JSON.parse(readFileSync(options.fixture, 'utf8'));
  const dir = mkdtempSync(join(tmpdir(), 'pcap-eval-'));
  const path = join(dir, 'store.sqlite');
  const keyFile = join(dir, 'master.key');
  const key = randomBytes(32);
  writeFileSync(keyFile, key.toString('hex'), { mode: 0o600 });
  try {
    // The store, seeded through the reference, which writes the store any implementation reads.
    const store = openStore(path, { masterKey: key });
    let captures = fixture.captures;
    if (options.days > 0) {
      const { filler } = await import(join(ROOT, 'eval/filler.js'));
      const last = fixture.captures.map((c) => c.at).sort().at(-1);
      captures = [...captures, ...filler({ days: options.days, perDay: options.perDay, end: last, seed: 42 })]
        .sort((a, b) => a.at.localeCompare(b.at));
    }
    const batch = [];
    const flush = () => {
      if (batch.length) store.appendAll(batch.splice(0));
    };
    for (const c of captures) {
      batch.push({
        captureId: c.id, capturedAt: c.at, captureType: c.type, privacyLevel: 'standard', contentText: c.text,
        source: c.type === 'audio_transcript' ? 'ambient_audio' : c.type === 'activity' ? 'activity' : 'screen',
        sourceApp: c.app, extraction: c.type === 'audio_transcript' ? 'asr' : c.type === 'activity' ? 'none' : 'ocr',
      });
      if (batch.length === 1000) flush();
    }
    flush();
    const grantId = store.issueGrant({ clientId: 'pcap-eval', expiresAt: '2099-01-01T00:00:00.000Z' });
    store.close();

    if (options.embed) {
      const ran = spawnSync(options.embed[0], [...options.embed.slice(1), '--store', path, '--master-key-file', keyFile], { stdio: 'inherit' });
      if (ran.status !== 0) throw new Error(`the embedding command failed (${ran.status})`);
    }

    const server = startServer(options.server, { path, grantId, keyFile });
    try {
      await server.initialize();
      const { ms: coldStartMs } = await server.call('recent', { limit: 1 });
      const span = { from: fixture.captures.map((c) => c.at).sort()[0], to: fixture.captures.map((c) => c.at).sort().at(-1) };
      const ask = (question) => server.call(question.ask.tool, { ...question.ask, tool: undefined, limit: 10 });

      /** Every question once, then the other tools 20 times each, each call `pace` ms after the last. */
      const timed = async (pace, onAnswer = () => {}) => {
        const latency = { search: [], recent: [], timeline: [], now: [] };
        for (const question of fixture.questions) {
          if (pace) await sleep(pace);
          const { answer, ms } = await ask(question);
          latency.search.push(ms);
          onAnswer(question, answer);
        }
        const others = [['recent', { limit: 10 }], ['timeline', { ...span, limit: 50 }], ['now', {}]];
        for (let i = 0; i < 20; i++) {
          for (const [tool, args] of others) {
            if (pace) await sleep(pace);
            latency[tool].push((await server.call(tool, args)).ms);
          }
        }
        return latency;
      };
      const summary = (latency) => Object.fromEntries(Object.entries(latency).map(([tool, values]) => [tool, { p50: percentile(values, 50), p95: percentile(values, 95) }]));

      // Quiet: the scores, and latency with nothing new to index.
      const results = [];
      const quiet = summary(await timed(0, (question, answer) => {
        const ids = captureIds(answer);
        const rank = ids.findIndex((id) => question.expect.includes(id));
        results.push({ id: question.id, kind: question.kind, rank: rank === -1 ? null : rank + 1, top: ids.slice(0, 5) });
      }));

      // Writing: the same calls while the writer appends, a batch apart.
      const writer = await startWriter({ path, keyFile });
      let writing;
      try {
        writing = summary(await timed(PACE_MS));
      } catch (err) {
        await writer.stop().catch(() => {});
        throw err;
      }
      const written = await writer.stop();

      const score = (subset) => ({
        questions: subset.length,
        recallAt1: subset.filter((r) => r.rank === 1).length / (subset.length || 1),
        recallAt5: subset.filter((r) => r.rank !== null && r.rank <= 5).length / (subset.length || 1),
        mrr: subset.reduce((sum, r) => sum + (r.rank ? 1 / r.rank : 0), 0) / (subset.length || 1),
      });
      const rounded = (summaryOf) => Object.fromEntries(Object.entries(summaryOf).map(([tool, l]) => [tool, { p50: Math.round(l.p50), p95: Math.round(l.p95) }]));
      const report = {
        server: options.server.join(' '),
        captures: captures.length,
        coldStartMs: Math.round(coldStartMs),
        all: score(results),
        keyword: score(results.filter((r) => r.kind === 'keyword')),
        paraphrase: score(results.filter((r) => r.kind === 'paraphrase')),
        latencyMs: { quiet: rounded(quiet), writing: rounded(writing) },
        writtenDuringTiming: written,
        missed: results.filter((r) => r.rank === null || r.rank > 5).map((r) => r.id),
        target: TARGET,
      };
      // Gated on the measured percentile; rounding is for display only.
      report.pass = report.all.recallAt5 >= TARGET.recallAt5 && writing.search.p95 < TARGET.searchP95Ms;

      const pct = (x) => `${(x * 100).toFixed(0)}%`;
      const lines = (name, summaryOf) => Object.entries(summaryOf).map(([tool, l]) => `${tool.padEnd(10)} p50 ${String(l.p50).padStart(4)} ms   p95 ${String(l.p95).padStart(4)} ms   (${name})`);
      process.stdout.write([
        `pcap-eval — ${report.captures} captures, server: ${report.server}`,
        `cold start (first call, building memory): ${report.coldStartMs} ms`,
        ...['all', 'keyword', 'paraphrase'].map((k) => `${k.padEnd(10)} recall@1 ${pct(report[k].recallAt1).padStart(4)}  recall@5 ${pct(report[k].recallAt5).padStart(4)}  MRR ${report[k].mrr.toFixed(2)}  (${report[k].questions} questions)`),
        ...lines('quiet', report.latencyMs.quiet),
        ...lines(`writing: ${written} captures appended while timed`, report.latencyMs.writing),
        `missed in the top 5: ${report.missed.join(', ') || 'none'}`,
        `target: recall@5 ≥ ${pct(TARGET.recallAt5)}, search p95 < ${TARGET.searchP95Ms} ms while writing — ${report.pass ? 'PASS' : 'FAIL'}`,
        '',
      ].join('\n'));
      if (options.json) writeFileSync(options.json, `${JSON.stringify({ ...report, results }, null, 2)}\n`);
      if (options.gate && !report.pass) process.exitCode = 1;
    } finally {
      await server.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// A run that stops before reporting never exits 0, however it stopped.
let finished = false;
process.on('exit', (code) => {
  if (!finished && code === 0) process.exitCode = 2;
});
main().then(() => { finished = true; }, (err) => {
  process.stderr.write(`pcap-eval: ${err.message}\n`);
  process.exit(2);
});
