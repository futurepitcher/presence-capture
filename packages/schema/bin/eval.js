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
 * questions and for keyword and paraphrase questions apart, and p50 and p95
 * latency for each tool, after a first call that builds the server's memory
 * (cold start, reported on its own). It exits 1 below the targets the release
 * plan sets: recall@5 at least 0.80, search p95 under 300 ms. --no-gate only
 * reports.
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

/** An MCP server over stdio, as a client starts one. */
function startServer(command, { path, grantId, keyFile }) {
  const server = spawn(command[0], [...command.slice(1), '--store', path, '--grant', grantId, '--master-key-file', keyFile], {
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const waiting = new Map();
  eachLine(server.stdout, (line) => {
    if (line.trim() === '') return;
    const message = JSON.parse(line);
    waiting.get(message.id)?.(message);
    waiting.delete(message.id);
  });
  let nextId = 1;
  const rpc = (method, params) => new Promise((done) => {
    const id = nextId++;
    waiting.set(id, done);
    server.stdin.write(jsonLine({ jsonrpc: '2.0', id, method, params }));
  });
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
    if (server.exitCode === null) await new Promise((done) => server.once('close', done));
  };
  return { rpc, call, close };
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
    await server.rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'pcap-eval', version: '1' } });
    try {
      const { ms: coldStartMs } = await server.call('recent', { limit: 1 });

      const latency = { search: [], recent: [], timeline: [], now: [] };
      const results = [];
      for (const question of fixture.questions) {
        const { answer, ms } = await server.call(question.ask.tool, { ...question.ask, tool: undefined, limit: 10 });
        latency.search.push(ms);
        const ids = captureIds(answer);
        const rank = ids.findIndex((id) => question.expect.includes(id));
        results.push({ id: question.id, kind: question.kind, rank: rank === -1 ? null : rank + 1, top: ids.slice(0, 5) });
      }
      const span = { from: fixture.captures.map((c) => c.at).sort()[0], to: fixture.captures.map((c) => c.at).sort().at(-1) };
      for (let i = 0; i < 20; i++) {
        latency.recent.push((await server.call('recent', { limit: 10 })).ms);
        latency.timeline.push((await server.call('timeline', { ...span, limit: 50 })).ms);
        latency.now.push((await server.call('now', {})).ms);
      }

      const score = (subset) => ({
        questions: subset.length,
        recallAt1: subset.filter((r) => r.rank === 1).length / (subset.length || 1),
        recallAt5: subset.filter((r) => r.rank !== null && r.rank <= 5).length / (subset.length || 1),
        mrr: subset.reduce((sum, r) => sum + (r.rank ? 1 / r.rank : 0), 0) / (subset.length || 1),
      });
      const report = {
        server: options.server.join(' '),
        captures: captures.length,
        coldStartMs: Math.round(coldStartMs),
        all: score(results),
        keyword: score(results.filter((r) => r.kind === 'keyword')),
        paraphrase: score(results.filter((r) => r.kind === 'paraphrase')),
        latencyMs: Object.fromEntries(Object.entries(latency).map(([tool, values]) => [tool, { p50: Math.round(percentile(values, 50)), p95: Math.round(percentile(values, 95)) }])),
        missed: results.filter((r) => r.rank === null || r.rank > 5).map((r) => r.id),
        target: TARGET,
      };
      report.pass = report.all.recallAt5 >= TARGET.recallAt5 && report.latencyMs.search.p95 < TARGET.searchP95Ms;

      const pct = (x) => `${(x * 100).toFixed(0)}%`;
      process.stdout.write([
        `pcap-eval — ${report.captures} captures, server: ${report.server}`,
        `cold start (first call, building memory): ${report.coldStartMs} ms`,
        ...['all', 'keyword', 'paraphrase'].map((k) => `${k.padEnd(10)} recall@1 ${pct(report[k].recallAt1).padStart(4)}  recall@5 ${pct(report[k].recallAt5).padStart(4)}  MRR ${report[k].mrr.toFixed(2)}  (${report[k].questions} questions)`),
        ...Object.entries(report.latencyMs).map(([tool, l]) => `${tool.padEnd(10)} p50 ${String(l.p50).padStart(4)} ms   p95 ${String(l.p95).padStart(4)} ms`),
        `missed in the top 5: ${report.missed.join(', ') || 'none'}`,
        `target: recall@5 ≥ ${pct(TARGET.recallAt5)}, search p95 < ${TARGET.searchP95Ms} ms — ${report.pass ? 'PASS' : 'FAIL'}`,
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

main().catch((err) => {
  process.stderr.write(`pcap-eval: ${err.message}\n`);
  process.exit(2);
});
