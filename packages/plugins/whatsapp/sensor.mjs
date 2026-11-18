#!/usr/bin/env node
/**
 * whatsapp: a sensor plugin (ADR 0007) that notes the text messages of every
 * WhatsApp chat on this Mac, read from WhatsApp Desktop's own database.
 *
 * EXPERIMENTAL: see docs/sources/whatsapp.md. Its captures are `standard`,
 * so any agent with a default grant can read them: don't connect an agent
 * while it runs. It runs once a person adds it (`--install`) and approves it
 * in Presence Capture, whose approval says what it keeps.
 *
 * Usage:
 *   sensor.mjs --install [--config <sensors.json>]
 *   sensor.mjs --experimental [--from both|me] [--history-days <n> | --since <ISO time>]
 *              [--name <sensor-name>] [--exclude-file <path>] [--db <path>] [--once] [--every <seconds>]
 *   sensor.mjs --list-chats
 *
 * --install       adds this sensor to sensors.json, to be approved from the
 *                 app's menu, and makes the exclude list. Nothing runs yet.
 * --experimental  required: the command a person approves says so.
 * --from          both (the default) keeps every message in every chat; me
 *                 keeps only the person's own.
 * --name          the sensor's name, and so its source (sensor:<name>).
 *                 Defaults to whatsapp.
 * --history-days  also imports the history: messages from up to n days
 *                 before start (1 to 365). Without it, a day back. Messages
 *                 older than the store keeps (its retention) are refused by it.
 * --since         the same, from an exact time, no more than 365 days back.
 * --exclude-file  the chats never read, one a line, by name or id. Defaults to
 *                 whatsapp-exclude.txt beside the store. Read before every
 *                 query, so a chat added to it is skipped from the next one.
 * --list-chats    prints each chat's id, name, message count and the source
 *                 to forget it by, to stderr, then exits. It sends no
 *                 observation, so nothing it prints is stored.
 *
 * What it never does: write to WhatsApp's database (it's opened read-only, a
 * query at a time), copy it, read media, reach the network, or talk to
 * WhatsApp's servers. It only knows the columns below, and stops when they're
 * missing.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const DEFAULT_DB = join(homedir(), 'Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite');
// Where Presence Capture keeps its store, sensors.json and exclusion lists.
export const APP_HOME = process.env.PRESENCE_CAPTURE_HOME ?? join(homedir(), 'Library/Application Support/Presence Capture');
export const DEFAULT_EXCLUDE_FILE = join(APP_HOME, 'whatsapp-exclude.txt');
// Core Data stamps seconds since 2001-01-01T00:00:00Z.
export const APPLE_EPOCH_S = 978_307_200;
// The columns this reads. Unverified against every WhatsApp release: any one missing, and it stops.
export const REQUIRED = {
  ZWAMESSAGE: ['Z_PK', 'ZCHATSESSION', 'ZISFROMME', 'ZMESSAGEDATE', 'ZTEXT', 'ZSTANZAID'],
  ZWACHATSESSION: ['Z_PK', 'ZCONTACTJID'],
};
// The chat's name as WhatsApp shows it. Read when it's there; a chat is "Chat <n>" when it isn't.
const NAME_COLUMN = 'ZPARTNERNAME';
// The furthest back an import may reach.
export const HISTORY_MAX_DAYS = 365;
const DAY_MS = 86_400_000;
// A group's id ends in @g.us. In a group, other members are kept as "Member", never by name.
const GROUP = /@g\.us$/;
// Each chat's captures carry this, plus the chat's row, as their app: one chat is forgotten by it.
export const BUNDLE = 'net.whatsapp.WhatsApp';
export const chatSource = (chatPk) => `${BUNDLE}.chat-${chatPk}`;

export function parseArgs(argv) {
  const out = {
    from: 'both', name: 'whatsapp', db: DEFAULT_DB, excludeFile: DEFAULT_EXCLUDE_FILE, every: 30,
    once: false, listChats: false, experimental: false, install: false, config: join(APP_HOME, 'sensors.json'),
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => argv[(i += 1)];
    if (a === '--from') out.from = next();
    else if (a === '--name') out.name = next();
    else if (a === '--since') out.since = next();
    else if (a === '--history-days') out.historyDays = Number(next());
    else if (a === '--experimental') out.experimental = true;
    else if (a === '--exclude-file') out.excludeFile = next();
    else if (a === '--db') out.db = next();
    else if (a === '--every') out.every = Number(next());
    else if (a === '--once') out.once = true;
    else if (a === '--list-chats') out.listChats = true;
    else if (a === '--install') out.install = true;
    else if (a === '--config') out.config = next();
    else throw new Error(`unknown argument: ${a}`);
  }
  return out;
}

/** Null when the options are usable; otherwise why not. */
export function optionsError(o) {
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(o.name)) return '--name is lower-case letters, digits and hyphens';
  if (o.listChats || o.install) return null;
  if (!o.experimental) return 'this sensor is experimental: its command must say --experimental';
  if (!['me', 'both'].includes(o.from)) return '--from is me or both';
  if (o.since != null && o.historyDays != null) return '--since or --history-days, not both';
  if (o.historyDays != null && !(Number.isInteger(o.historyDays) && o.historyDays >= 1 && o.historyDays <= HISTORY_MAX_DAYS)) {
    return `--history-days is a whole number from 1 to ${HISTORY_MAX_DAYS}`;
  }
  if (o.since != null && Number.isNaN(Date.parse(o.since))) return '--since must be a time';
  if (o.since != null && Date.parse(o.since) < Date.now() - HISTORY_MAX_DAYS * DAY_MS) return `--since is at most ${HISTORY_MAX_DAYS} days back`;
  if (!(o.every >= 5)) return '--every is at least 5 seconds';
  return null;
}

/** The earliest moment a message is noted from: a day back unless the person asked for history. */
export function startFor(o, now = Date.now()) {
  if (o.since != null) return Date.parse(o.since);
  return now - (o.historyDays ?? 1) * DAY_MS;
}

/** Null when the database has every column this reads; otherwise what's missing. */
export function schemaError(db) {
  for (const [table, columns] of Object.entries(REQUIRED)) {
    const have = new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name));
    if (have.size === 0) return `no table ${table}`;
    const missing = columns.filter((c) => !have.has(c));
    if (missing.length) return `${table} lacks ${missing.join(', ')}`;
  }
  return null;
}

/** Opened read-only and query-only: nothing here can change WhatsApp's data. */
export function openReadOnly(path) {
  const db = new DatabaseSync(path, { readOnly: true });
  db.exec('PRAGMA query_only = 1');
  return db;
}

/**
 * The exclude list: chat names or ids, one a line, matched whole and in any
 * case. Lines starting with # are notes. A missing file excludes nothing; a
 * file that can't be read throws, so nothing is read until it can be.
 */
export function readExclusions(path) {
  if (!existsSync(path)) return new Set();
  return new Set(readFileSync(path, 'utf8').split(/\r?\n/).map((l) => l.trim().toLowerCase()).filter((l) => l && !l.startsWith('#')));
}

const nameSql = (db) => (db.prepare('PRAGMA table_info(ZWACHATSESSION)').all().some((c) => c.name === NAME_COLUMN) ? `s.${NAME_COLUMN}` : 'NULL');
const chatName = (name, chatPk) => (typeof name === 'string' && name.trim() ? name.trim() : `Chat ${chatPk}`);

/**
 * The text messages of every chat not excluded, sent after `sinceApple` (Core
 * Data seconds) and written to the database after row `afterPk`, in the order
 * they were written, as observations; and the last row looked at, excluded
 * chats' included, as the next watermark. The row is the watermark, not the
 * time, so a message that reaches this Mac late (synced from the phone) isn't
 * missed, and a chat taken off the exclude list starts from now, never from
 * what was skipped. A message with no text (media, a deleted message's
 * tombstone) is skipped, never read further.
 */
export function readMessages(db, { from, excluded = new Set() }, sinceApple, afterPk = 0) {
  const rows = db.prepare(`
    SELECT m.Z_PK AS pk, m.ZISFROMME AS mine, m.ZMESSAGEDATE AS date, m.ZTEXT AS text, m.ZSTANZAID AS stanza,
           s.Z_PK AS chatPk, s.ZCONTACTJID AS jid, ${nameSql(db)} AS name
    FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
    WHERE m.ZMESSAGEDATE > ? AND m.Z_PK > ?
      AND m.ZTEXT IS NOT NULL AND m.ZTEXT <> ''
      ${from === 'me' ? 'AND m.ZISFROMME = 1' : ''}
    ORDER BY m.Z_PK
  `).all(sinceApple, afterPk);
  let last = afterPk;
  const messages = [];
  for (const r of rows) {
    last = Math.max(last, r.pk);
    const name = chatName(r.name, r.chatPk);
    if (excluded.has(name.toLowerCase()) || (r.jid && excluded.has(String(r.jid).toLowerCase()))) continue;
    const who = r.mine ? 'Me' : GROUP.test(r.jid ?? '') ? 'Member' : name;
    messages.push({
      at: new Date((r.date + APPLE_EPOCH_S) * 1000).toISOString(),
      kind: 'screen',
      app: 'WhatsApp',
      // Kept as the capture's app, so one chat's captures can be forgotten together.
      bundle: chatSource(r.chatPk),
      window: `WhatsApp: ${name}`,
      text: `[${name}] ${who}: ${r.text}`,
      // A message's own id: a restarted sensor adds nothing, and a revoked message never comes back.
      dedupe: `wa:${r.stanza ?? `pk-${r.pk}`}`.slice(0, 200),
    });
  }
  return { messages, last };
}

/** JSON a line, with U+2028 and U+2029 escaped so a line ends at \n alone. */
export const line = (value) => `${JSON.stringify(value).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029')}\n`;

function listChats(db) {
  const rows = db.prepare(`
    SELECT s.Z_PK AS chatPk, s.ZCONTACTJID AS jid, ${nameSql(db)} AS name, COUNT(m.Z_PK) AS messages
    FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
    GROUP BY s.Z_PK ORDER BY messages DESC
  `).all();
  for (const r of rows) {
    process.stderr.write(`${chatName(r.name, r.chatPk)}\t${r.jid}\t${r.messages}\t${chatSource(r.chatPk)}${GROUP.test(r.jid ?? '') ? '\tgroup' : ''}\n`);
  }
}

const EXCLUDE_NOTE = `# WhatsApp chats Presence Capture never reads, one a line: the chat's name as
# WhatsApp shows it, or its id. A line matches a whole name, in any case.
# Saved changes apply from the next read, within a minute. Lines starting with # are notes.
# What was already kept from a chat stays until it's forgotten: see docs/sources/whatsapp.md.
#
# Family
# 15555550100@s.whatsapp.net
`;

/**
 * Adds this sensor to sensors.json, unapproved, and makes the exclude list. The
 * app runs it only once the person approves it from its menu, where it says what
 * it keeps. Returns what it did, for the person.
 */
export function install(o, { node = process.execPath, script = fileURLToPath(import.meta.url) } = {}) {
  const entries = existsSync(o.config) ? JSON.parse(readFileSync(o.config, 'utf8')) : [];
  if (!Array.isArray(entries)) throw new Error(`${o.config} isn't a list of sensors`);
  if (entries.some((e) => e?.name === o.name)) throw new Error(`a sensor named ${o.name} is already in ${o.config}`);
  const command = [node, script, '--experimental', ...(o.name === 'whatsapp' ? [] : ['--name', o.name])];
  entries.push({ name: o.name, command });
  mkdirSync(dirname(o.config), { recursive: true, mode: 0o700 });
  const temp = `${o.config}.${process.pid}.tmp`;
  writeFileSync(temp, `${JSON.stringify(entries, null, 2)}\n`, { mode: 0o600 });
  renameSync(temp, o.config);
  if (!existsSync(o.excludeFile)) {
    mkdirSync(dirname(o.excludeFile), { recursive: true, mode: 0o700 });
    writeFileSync(o.excludeFile, EXCLUDE_NOTE, { mode: 0o600 });
  }
  return { command };
}

function main() {
  let o;
  try {
    o = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exit(2);
  }
  const error = optionsError(o);
  if (error) {
    process.stderr.write(`${error}\n`);
    process.exit(2);
  }

  if (o.install) {
    try {
      install(o);
    } catch (err) {
      process.stderr.write(`${err.message}\n`);
      process.exit(1);
    }
    process.stderr.write(`Added "${o.name}" to ${o.config}. Nothing runs yet: in Presence Capture's menu, choose Approve 1 Sensor…, `
      + `read what it keeps, and approve it. Chats to skip go in ${o.excludeFile}.\n`);
    return;
  }

  if (o.listChats) {
    const db = openReadOnly(o.db);
    try {
      const why = schemaError(db);
      if (why) throw new Error(`not a WhatsApp database this sensor knows: ${why}`);
      listChats(db);
    } finally {
      db.close();
    }
    return;
  }

  process.stderr.write('experimental: captures are standard and readable by any agent with a default grant; see docs/sources/whatsapp.md\n');
  process.stdout.write(line({ sensor: o.name, protocol: '1' }));
  const sinceApple = startFor(o) / 1000 - APPLE_EPOCH_S;
  let afterPk = 0;

  const poll = () => {
    // Opened and closed each time, so it never holds WhatsApp's database open between reads.
    let db;
    try {
      // Read first: an exclude list that can't be read means nothing is read this time.
      const excluded = readExclusions(o.excludeFile);
      db = openReadOnly(o.db);
      const why = schemaError(db);
      if (why) {
        process.stderr.write(`stopped: not a WhatsApp database this sensor knows (${why})\n`);
        process.exit(1);
      }
      const { messages, last } = readMessages(db, { from: o.from, excluded }, sinceApple, afterPk);
      for (const observation of messages) process.stdout.write(line(observation));
      afterPk = last;
    } catch (err) {
      // Unreadable (no permission yet, WhatsApp mid-write, the exclude list): try again next time, and say why on stderr.
      process.stderr.write(`could not read: ${err.message}\n`);
    } finally {
      db?.close();
    }
  };

  poll();
  if (!o.once) setInterval(poll, o.every * 1000);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
