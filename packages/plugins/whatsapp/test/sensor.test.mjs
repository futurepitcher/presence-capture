import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { runSensor } from '../../../schema/src/sensor-host.js';
import { openStore } from '../../../schema/src/store.js';
import { checkSensor } from '../../../schema/conformance/plugins/sensor-kit.js';
import { chatSource, install, openReadOnly, optionsError, parseArgs, readExclusions, readMessages, schemaError } from '../sensor.mjs';
import { ago, buildFixture, CHAT_A, CHAT_B, GROUP } from './fixture.mjs';

const SENSOR = new URL('../sensor.mjs', import.meta.url).pathname;
const exclusions = (fx) => join(fx.dir, 'whatsapp-exclude.txt');
const command = (fx, ...more) => [process.execPath, SENSOR, '--experimental', '--once', '--db', fx.path, '--exclude-file', exclusions(fx), ...more];
const texts = (store, ids) => ids.map((id) => JSON.stringify(store.contentText(id)));

test('whatsapp: the sensor kit passes it', async () => {
  const fx = buildFixture();
  try {
    assert.deepEqual(await checkSensor(command(fx)), []);
  } finally {
    fx.cleanup();
  }
});

test('whatsapp: every chat, both sides, by default; text only, each message under its chat, a key redacted', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const { name, stats } = await runSensor({ command: command(fx), store });
    assert.equal(name, 'whatsapp');
    assert.equal(stats.appended, 7, 'every text message of the last day, in every chat; the photo left out');
    assert.equal(stats.redacted, 1);
    const all = texts(store, stats.captureIds).join('\n');
    assert.match(all, /\[Alex\] Me: Morning, are we still on for the demo\?/);
    assert.match(all, /\[Alex\] Alex: Yes, 3pm works\./);
    assert.match(all, /\[Sam\] Sam: From Sam\./);
    assert.match(all, /\[Project Team\] Member: Group hello from a member\./, 'a group member was named');
    assert.doesNotMatch(all, /sk-ant-api03/, 'a key in a message was stored');
    assert.doesNotMatch(all, /Forty days ago/, 'history was read without being asked for');
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: --from me keeps only the person\'s own messages', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const { stats } = await runSensor({ command: command(fx, '--from', 'me'), store });
    assert.equal(stats.appended, 4);
    assert.doesNotMatch(texts(store, stats.captureIds).join('\n'), /3pm works|From Sam|from a member/);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: a chat on the exclude list, by name or id, is never read', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    writeFileSync(exclusions(fx), `# notes are skipped\n  sam  \n${GROUP.toUpperCase()}\n`);
    const { stats } = await runSensor({ command: command(fx), store });
    assert.equal(stats.appended, 3, 'only Alex is left');
    const all = texts(store, stats.captureIds).join('\n');
    assert.doesNotMatch(all, /Sam|Project Team/);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: a chat excluded while it runs is skipped from the next read, and taken off the list it starts from then', () => {
  const fx = buildFixture();
  const db = () => openReadOnly(fx.path);
  try {
    const first = db();
    const one = readMessages(first, { from: 'both' }, 0, 0);
    first.close();
    // Excluded now: what arrives next in that chat isn't read, though the watermark passes it.
    fx.add(CHAT_B, 0, ago(1), 'Sam again.', 'STANZA-B3');
    fx.add(CHAT_A, 0, ago(1), 'Alex again.', 'STANZA-A6');
    const second = db();
    const two = readMessages(second, { from: 'both', excluded: readExclusionsFrom(fx, 'Sam') }, 0, one.last);
    second.close();
    assert.deepEqual(two.messages.map((m) => m.text), ['[Alex] Alex: Alex again.']);
    // Off the list again: nothing skipped while it was on comes back.
    const third = db();
    assert.deepEqual(readMessages(third, { from: 'both' }, 0, two.last).messages, []);
    third.close();
  } finally {
    fx.cleanup();
  }
});

function readExclusionsFrom(fx, ...lines) {
  writeFileSync(exclusions(fx), lines.join('\n'));
  return readExclusions(exclusions(fx));
}

test('whatsapp: one chat\'s messages are forgotten together, and only that chat\'s', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const cmd = command(fx);
    const { stats } = await runSensor({ command: cmd, store });
    assert.equal(stats.appended, 7);
    const { revokedCaptureIds } = store.revoke({ scopeKind: 'source', scopeValue: chatSource(fx.chatPk(CHAT_A)) });
    assert.equal(revokedCaptureIds.length, 3, 'Alex\'s three messages, and nothing else');
    const kept = stats.captureIds.filter((id) => store.contentText(id) != null);
    assert.equal(kept.length, 4);
    assert.doesNotMatch(texts(store, kept).join('\n'), /\[Alex\]/);
    // Read again, nothing forgotten comes back, and nothing kept is doubled.
    const again = await runSensor({ command: cmd, store });
    assert.equal(again.stats.appended, 0, 'a forgotten message came back');
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: a restarted sensor adds nothing, and the whole sensor is revoked by its source', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const cmd = command(fx);
    const first = await runSensor({ command: cmd, store });
    assert.equal(first.stats.appended, 7);
    const again = await runSensor({ command: cmd, store });
    assert.equal(again.stats.appended, 0);
    assert.equal(again.stats.duplicates, 7);
    const { revokedCaptureIds } = store.revoke({ scopeKind: 'source', scopeValue: 'sensor:whatsapp' });
    assert.equal(revokedCaptureIds.length, 7);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: a message that arrives later is picked up by the next read', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const cmd = command(fx);
    await runSensor({ command: cmd, store });
    // Sent earlier, written to this Mac later (synced from the phone).
    fx.add(CHAT_A, 1, ago(4.95), 'Late arrival.', 'STANZA-A5');
    const { stats } = await runSensor({ command: cmd, store });
    assert.equal(stats.appended, 1);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: the app\'s own exclusion list works on it too, for the app or one chat', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    // As the exclusion list keeps its lines, lower-cased.
    const all = await runSensor({ command: command(fx), store, fragments: ['whatsapp'] });
    assert.equal(all.stats.appended, 0);
    assert.equal(all.stats.excluded, 7);
    const one = await runSensor({ command: command(fx), store, fragments: ['whatsapp: sam'] });
    assert.equal(one.stats.appended, 5);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: a chat with no name in the database is kept as its row, never its number', async () => {
  const fx = buildFixture({ names: false });
  const store = openStore();
  try {
    const { stats } = await runSensor({ command: command(fx), store });
    assert.equal(stats.appended, 7);
    const all = texts(store, stats.captureIds).join('\n');
    assert.match(all, new RegExp(`\\[Chat ${fx.chatPk(CHAT_A)}\\] Me: Morning`));
    assert.doesNotMatch(all, /15555550100/);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: options it refuses', () => {
  const ok = ['--experimental'];
  assert.equal(optionsError(parseArgs(ok)), null);
  assert.match(optionsError(parseArgs([])), /experimental/, 'ran without saying it is experimental');
  assert.match(optionsError(parseArgs([...ok, '--history-days', '366'])), /--history-days/);
  assert.match(optionsError(parseArgs([...ok, '--history-days', '0'])), /--history-days/);
  assert.match(optionsError(parseArgs([...ok, '--history-days', '7', '--since', ago(24)])), /not both/);
  assert.match(optionsError(parseArgs([...ok, '--since', ago(24 * 400)])), /365 days/);
  assert.match(optionsError(parseArgs([...ok, '--from', 'everyone'])), /--from/);
  assert.match(optionsError(parseArgs([...ok, '--name', 'WhatsApp Alex'])), /--name/);
  assert.throws(() => parseArgs(['--send', 'hi']), /unknown argument/);
  assert.throws(() => parseArgs(['--chat', CHAT_A]), /unknown argument/, 'per-chat mode is gone: every chat, less the exclude list');
});

test('whatsapp: --install adds it unapproved, beside what\'s there, once', () => {
  const fx = buildFixture();
  try {
    const config = join(fx.dir, 'sensors.json');
    writeFileSync(config, JSON.stringify([{ name: 'git-activity', command: ['/bin/true'] }]));
    const o = { ...parseArgs(['--install', '--config', config, '--exclude-file', exclusions(fx)]) };
    install(o, { node: '/opt/homebrew/bin/node', script: '/path/to/sensor.mjs' });
    const entries = JSON.parse(readFileSync(config, 'utf8'));
    assert.deepEqual(entries.map((e) => e.name), ['git-activity', 'whatsapp']);
    assert.deepEqual(entries[1], { name: 'whatsapp', command: ['/opt/homebrew/bin/node', '/path/to/sensor.mjs', '--experimental'] });
    assert.equal(entries[1].pins, undefined, 'it was approved for the person');
    assert.match(readFileSync(exclusions(fx), 'utf8'), /never reads/);
    assert.throws(() => install(o), /already/);
  } finally {
    fx.cleanup();
  }
});

test('whatsapp: it never writes to WhatsApp\'s database', async () => {
  const fx = buildFixture();
  const hash = () => createHash('sha256').update(readFileSync(fx.path)).digest('hex');
  try {
    const before = hash();
    await runSensor({ command: command(fx), store: openStore() });
    assert.equal(hash(), before);
    const db = openReadOnly(fx.path);
    assert.throws(() => db.exec("INSERT INTO ZWAMESSAGE (ZTEXT) VALUES ('x')"), /readonly|query_only/i);
    db.close();
  } finally {
    fx.cleanup();
  }
});

test('whatsapp: a database it doesn\'t recognise stops it, rather than guessing', async () => {
  const fx = buildFixture();
  try {
    const { DatabaseSync } = await import('node:sqlite');
    const w = new DatabaseSync(fx.path);
    w.exec('ALTER TABLE ZWAMESSAGE RENAME COLUMN ZTEXT TO ZBODY');
    w.close();
    const db = openReadOnly(fx.path);
    assert.match(schemaError(db), /ZWAMESSAGE lacks ZTEXT/);
    db.close();
    const store = openStore();
    const { stats } = await runSensor({ command: command(fx), store });
    assert.equal(stats.appended, 0);
    store.close();
  } finally {
    fx.cleanup();
  }
});

test('whatsapp: history is imported only when asked, and kept only as long as the store keeps anything', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const cmd = command(fx, '--history-days', '60');
    const { stats } = await runSensor({ command: cmd, store });
    assert.equal(stats.appended, 9, 'two from history and seven from the last day');

    // A shorter retention (14 days here) treats an imported message like any capture: the one older than it is erased.
    store.retain({ days: 14, now: new Date() });
    const kept = stats.captureIds.filter((id) => store.contentText(id) != null);
    const all = texts(store, kept).join('\n');
    assert.match(all, /\[Alex\] Alex: Ten days ago, from them\./);
    assert.doesNotMatch(all, /Forty days ago/, 'history older than retention outlived it');

    // Importing again brings back nothing that retention erased.
    const again = await runSensor({ command: cmd, store });
    assert.equal(again.stats.appended, 0);
    assert.equal(again.stats.refused, 1);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: an exclude list that can\'t be read means nothing is read', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    // A directory where the list should be: unreadable as a file.
    const { mkdirSync } = await import('node:fs');
    mkdirSync(exclusions(fx));
    const { stats } = await runSensor({ command: command(fx), store });
    assert.equal(stats.appended, 0);
  } finally {
    store.close();
    fx.cleanup();
  }
});
