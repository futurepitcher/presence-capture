#!/usr/bin/env node
/**
 * git-activity: a sensor plugin (ADR 0007) that notes each commit made in the
 * repositories it's given, as activity: "repo — subject". An example of a
 * sensor in a few dozen lines, in any language: it writes observations to
 * stdout, and the host excludes, redacts and seals them.
 *
 * Usage:
 *   sensor.mjs [--once] [--every <seconds>] <repo> [<repo>...]
 *
 * --once notes the last day's commits and exits; otherwise it watches.
 */

import { execFileSync } from 'node:child_process';
import { basename, resolve } from 'node:path';

const args = process.argv.slice(2);
const once = args.includes('--once');
const everyAt = args.indexOf('--every');
const every = everyAt === -1 ? 30 : Number(args[everyAt + 1]);
const repos = args.filter((a, i) => !a.startsWith('--') && i !== everyAt + 1).map((r) => resolve(r));

const emit = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
emit({ sensor: 'git-activity', protocol: '1' });

const seen = new Set();
let since = new Date(Date.now() - 86_400_000);

function poll() {
  const until = new Date();
  for (const repo of repos) {
    let log = '';
    try {
      // Arguments, never a shell: a repository path can't become a command.
      log = execFileSync('git', ['-C', repo, 'log', `--since=${since.toISOString()}`, '--format=%H%x1f%cI%x1f%s'], { encoding: 'utf8' });
    } catch {
      continue;
    }
    for (const line of log.split('\n').filter(Boolean).reverse()) {
      const [hash, committed, subject] = line.split('\x1f');
      if (seen.has(hash)) continue;
      seen.add(hash);
      // The commit hash as dedupe: restarted, it sends the last day's commits
      // again, and the store keeps each once (and never one that was revoked).
      emit({ at: new Date(committed).toISOString(), kind: 'activity', app: 'git', window: `${basename(repo)} — ${subject}`, state: 'active', dedupe: hash });
    }
  }
  since = new Date(until.getTime() - 60_000);
}

poll();
if (!once) setInterval(poll, every * 1000);
