import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runSensor } from '../../../schema/src/sensor-host.js';
import { openStore } from '../../../schema/src/store.js';
import { checkSensor } from '../../../schema/conformance/plugins/sensor-kit.js';
import { openReadOnly, optionsError, parseArgs, schemaError } from '../sensor.mjs';
import { ago, buildFixture, CHAT_A, GROUP } from './fixture.mjs';

const SENSOR = new URL('../sensor.mjs', import.meta.url).pathname;
const command = (db, ...more) => [process.execPath, SENSOR, '--experimental', '--once', '--db', db, ...more];
const texts = (store, ids) => ids.map((id) => JSON.stringify(store.contentText(id)));

test('whatsapp: the sensor kit passes it', async () => {
  const fx = buildFixture();
  try {
    assert.deepEqual(await checkSensor(command(fx.path, '--chat', CHAT_A, '--label', 'Alex')), []);
  } finally {
    fx.cleanup();
  }
});

test('whatsapp: only the chat it was given, only the person\'s own messages, text only, a key redacted', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const { name, stats } = await runSensor({ command: command(fx.path, '--chat', CHAT_A, '--label', 'Alex'), store });
    assert.equal(name, 'whatsapp');
    assert.equal(stats.appended, 2, 'two of my text messages in chat A; theirs, the photo and other chats left out');
    assert.equal(stats.redacted, 1);
    const all = texts(store, stats.captureIds).join('\n');
    assert.match(all, /Me: Morning, are we still on for the demo\?/);
    assert.doesNotMatch(all, /3pm works/, 'the other side was kept without --from both');
    assert.doesNotMatch(all, /Not on the list/, 'another chat was read');
    assert.doesNotMatch(all, /sk-ant-api03/, 'a key in a message was stored');
    assert.doesNotMatch(all, /Synthetic Contact/, 'the contact\'s WhatsApp name was stored');
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: --from both keeps the other side, named by the label the person chose', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const { stats } = await runSensor({ command: command(fx.path, '--chat', CHAT_A, '--label', 'Alex', '--from', 'both'), store });
    assert.equal(stats.appended, 3);
    assert.match(texts(store, stats.captureIds).join('\n'), /Alex: Yes, 3pm works\./);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: a restarted sensor adds nothing, and a revoked chat doesn\'t come back', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const cmd = command(fx.path, '--chat', CHAT_A, '--label', 'Alex', '--name', 'whatsapp-alex');
    const first = await runSensor({ command: cmd, store });
    assert.equal(first.stats.appended, 2);
    const again = await runSensor({ command: cmd, store });
    assert.equal(again.stats.appended, 0);
    assert.equal(again.stats.duplicates, 2);

    // One chat, one source: it's revoked, and erased, alone.
    const { revokedCaptureIds } = store.revoke({ scopeKind: 'source', scopeValue: 'sensor:whatsapp-alex' });
    assert.equal(revokedCaptureIds.length, 2);
    const after = await runSensor({ command: cmd, store });
    assert.equal(after.stats.appended, 0, 'a revoked message came back');
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: a message that arrives later is picked up by the next read', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const cmd = command(fx.path, '--chat', CHAT_A, '--label', 'Alex');
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

test('whatsapp: excluding the WhatsApp app drops everything it sends', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const { stats } = await runSensor({ command: command(fx.path, '--chat', CHAT_A, '--label', 'Alex'), store, fragments: ['whatsapp'] }); // as the exclusion list keeps it, lower-cased
    assert.equal(stats.appended, 0);
    assert.equal(stats.excluded, 2);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: groups are refused unless asked for, and members are never named', async () => {
  assert.match(optionsError(parseArgs(['--experimental', '--chat', GROUP, '--label', 'Team'])), /--allow-group/);
  const fx = buildFixture();
  const store = openStore();
  try {
    const { stats } = await runSensor({ command: command(fx.path, '--chat', GROUP, '--label', 'Team', '--allow-group', '--from', 'both'), store });
    assert.equal(stats.appended, 2);
    const all = texts(store, stats.captureIds).join('\n');
    assert.match(all, /Member: Group hello from a member\./);
  } finally {
    store.close();
    fx.cleanup();
  }
});

test('whatsapp: options it refuses', () => {
  const ok = ['--experimental', '--chat', CHAT_A, '--label', 'Alex'];
  assert.equal(optionsError(parseArgs(ok)), null);
  assert.match(optionsError(parseArgs(ok.slice(1))), /experimental/, 'ran without saying it is experimental');
  assert.match(optionsError(parseArgs([...ok, '--history-days', '366'])), /--history-days/);
  assert.match(optionsError(parseArgs([...ok, '--history-days', '0'])), /--history-days/);
  assert.match(optionsError(parseArgs([...ok, '--history-days', '7', '--since', ago(24)])), /not both/);
  assert.match(optionsError(parseArgs([...ok, '--since', ago(24 * 400)])), /365 days/);
  assert.match(optionsError(parseArgs(['--experimental', '--label', 'Alex'])), /--chat/);
  assert.match(optionsError(parseArgs(['--experimental', '--chat', CHAT_A])), /--label/);
  assert.match(optionsError(parseArgs([...ok, '--from', 'everyone'])), /--from/);
  assert.match(optionsError(parseArgs([...ok, '--name', 'WhatsApp Alex'])), /--name/);
  assert.throws(() => parseArgs(['--send', 'hi']), /unknown argument/);
});

test('whatsapp: it never writes to WhatsApp\'s database', async () => {
  const fx = buildFixture();
  const hash = () => createHash('sha256').update(readFileSync(fx.path)).digest('hex');
  try {
    const before = hash();
    await runSensor({ command: command(fx.path, '--chat', CHAT_A, '--label', 'Alex'), store: openStore() });
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
    const { stats } = await runSensor({ command: command(fx.path, '--chat', CHAT_A, '--label', 'Alex'), store });
    assert.equal(stats.appended, 0);
    store.close();
  } finally {
    fx.cleanup();
  }
});

test('whatsapp: history is imported only when asked, for that chat, and kept only as long as the store keeps anything', async () => {
  const fx = buildFixture();
  const store = openStore();
  try {
    const cmd = command(fx.path, '--chat', CHAT_A, '--label', 'Alex', '--from', 'both', '--history-days', '60');
    const { stats } = await runSensor({ command: cmd, store });
    assert.equal(stats.appended, 5, 'two from history and three from the last day');

    // Retention (14 days here) treats an imported message like any capture: the one older than it is erased.
    store.retain({ days: 14, now: new Date() });
    const kept = stats.captureIds.filter((id) => store.contentText(id) != null);
    const all = texts(store, kept).join('\n');
    assert.match(all, /Alex: Ten days ago, from them\./);
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
