#!/usr/bin/env node
/**
 * Fill a store from a fixture, as the fake sensor would have captured it.
 *
 * Usage:
 *   replay-fixture --store <path> --master-key-file <path> <fixture.jsonl>
 *
 * The master key file is created, with a fresh key, when it doesn't exist.
 */

import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { parseFixture, replayFixture } from '../src/fake-sensor.js';
import { openStore } from '../src/store.js';

const arg = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
};

const storePath = arg('store');
const keyFile = arg('master-key-file');
const fixture = process.argv.at(-1);

if (!storePath || !keyFile || !fixture?.endsWith('.jsonl')) {
  process.stderr.write('usage: replay-fixture --store <path> --master-key-file <path> <fixture.jsonl>\n');
  process.exit(2);
}

if (!existsSync(keyFile)) writeFileSync(keyFile, randomBytes(32).toString('hex'), { mode: 0o600 });
const masterKey = Buffer.from(readFileSync(keyFile, 'utf8').trim(), 'hex');

const store = openStore(storePath, { masterKey });
const { appended, excluded, redacted } = replayFixture(store, parseFixture(readFileSync(fixture, 'utf8')));
store.close();

// Counts only: never what was captured.
process.stdout.write(`appended ${appended}, excluded ${excluded}, redacted ${redacted}\n`);
