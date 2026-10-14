/**
 * A writer beside the server while pcap-eval times it, as the daemon writes
 * while an agent reads: every quarter second, a batch of a screen capture, an
 * activity and an utterance, appended together (BEGIN IMMEDIATE, as the
 * daemon's writers do): twelve captures a second, where the daemon samples
 * every five seconds. The text is filler, so it never answers a question.
 *
 *   node eval/writer.js <store> <master-key-file>
 *
 * It prints {"started": true} once its first batch is in, writes until its
 * stdin closes, then prints {"written": n} and exits.
 */

import { readFileSync } from 'node:fs';
import { openStore } from '../packages/schema/src/store.js';
import { filler } from './filler.js';

const EVERY_MS = 250;

const [path, keyFile] = process.argv.slice(2);
const store = openStore(path, { masterKey: Buffer.from(readFileSync(keyFile, 'utf8').trim(), 'hex') });
const pool = filler({ days: 1, perDay: 300, end: new Date().toISOString(), seed: 7 });
const ofType = (type) => pool.filter((c) => c.type === type);
const kinds = [
  { type: 'screen_text', source: 'screen', extraction: 'ocr', items: ofType('screen_text') },
  { type: 'activity', source: 'activity', extraction: 'none', items: ofType('activity') },
  { type: 'audio_transcript', source: 'ambient_audio', extraction: 'asr', items: ofType('audio_transcript') },
];

let written = 0;
const write = () => {
  const capturedAt = new Date().toISOString();
  const round = written / kinds.length;
  store.appendAll(kinds.map(({ type, source, extraction, items }) => {
    const c = items[round % items.length];
    return { capturedAt, captureType: type, source, extraction, privacyLevel: 'standard', sourceApp: c.app, contentText: c.text };
  }));
  written += kinds.length;
};

write();
process.stdout.write(`${JSON.stringify({ started: true })}\n`);
const tick = setInterval(write, EVERY_MS);

process.stdin.resume();
process.stdin.on('end', () => {
  clearInterval(tick);
  store.close();
  process.stdout.write(`${JSON.stringify({ written })}\n`);
});
