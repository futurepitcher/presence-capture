#!/usr/bin/env node
/**
 * whatsapp: a sensor plugin (ADR 0007) that notes the text messages of ONE
 * WhatsApp chat, read from WhatsApp Desktop's own database on this Mac.
 *
 * EXPERIMENTAL: see docs/sources/whatsapp.md. Its captures are `standard`,
 * so any agent with a default grant can read them: don't connect an agent
 * while it runs. Off unless a person lists it in sensors.json, with
 * --experimental in its command, and approves it, one chat per entry.
 *
 * Usage:
 *   sensor.mjs --experimental --chat <jid> --label <text> [--from me|both]
 *              [--history-days <n> | --since <ISO time>] [--name <sensor-name>]
 *              [--db <path>] [--once] [--every <seconds>]
 *
 * --experimental  required: the command a person approves says so.
 *
 * --chat    the chat's id in WhatsApp (as `--list-chats` prints it). One chat
 *           per sensor, so each chat is approved, paused and revoked alone.
 * --label   the name the person gives the chat. It's what's kept as the
 *           window: the contact's own WhatsApp name is never read.
 * --from    me (the default) keeps only the person's own messages; both keeps
 *           the other side's too.
 * --name    the sensor's name, and so its source (sensor:<name>). Defaults to
 *           whatsapp.
 * --history-days  imports this chat's history: messages from up to n days
 *           before start (1 to 365). Without it, a day back. Older messages
 *           than the store keeps (its retention) are refused by the store.
 * --since   the same, from an exact time, no more than 365 days back.
 * --list-chats  prints chat ids and message counts to stderr, then exits. It
 *           sends no observation, so nothing it prints is stored.
 *
 * What it never does: write to the database (it's opened read-only, a query
 * at a time), copy it, read media, reach the network, or talk to WhatsApp's
 * servers. It only knows the columns below, and stops when they're missing.
 */

import { DatabaseSync } from 'node:sqlite';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const DEFAULT_DB = join(homedir(), 'Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite');
// Core Data stamps seconds since 2001-01-01T00:00:00Z.
export const APPLE_EPOCH_S = 978_307_200;
// The columns this reads. Unverified against every WhatsApp release: any one missing, and it stops.
export const REQUIRED = {
  ZWAMESSAGE: ['Z_PK', 'ZCHATSESSION', 'ZISFROMME', 'ZMESSAGEDATE', 'ZTEXT', 'ZSTANZAID'],
  ZWACHATSESSION: ['Z_PK', 'ZCONTACTJID'],
};
// The furthest back an import may reach.
export const HISTORY_MAX_DAYS = 365;
const DAY_MS = 86_400_000;
// A group's id ends in @g.us. Groups are refused unless asked for by --allow-group.
const GROUP = /@g\.us$/;

export function parseArgs(argv) {
  const out = { from: 'me', name: 'whatsapp', db: DEFAULT_DB, every: 30, once: false, allowGroup: false, listChats: false, experimental: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => argv[(i += 1)];
    if (a === '--chat') out.chat = next();
    else if (a === '--label') out.label = next();
    else if (a === '--from') out.from = next();
    else if (a === '--name') out.name = next();
    else if (a === '--since') out.since = next();
    else if (a === '--history-days') out.historyDays = Number(next());
    else if (a === '--experimental') out.experimental = true;
    else if (a === '--db') out.db = next();
    else if (a === '--every') out.every = Number(next());
    else if (a === '--once') out.once = true;
    else if (a === '--allow-group') out.allowGroup = true;
    else if (a === '--list-chats') out.listChats = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  return out;
}

/** Null when the options are usable; otherwise why not. */
export function optionsError(o) {
  if (o.listChats) return null;
  if (!o.experimental) return 'this sensor is experimental: its command must say --experimental';
  if (!o.chat) return '--chat is required: one chat per sensor';
  if (!o.label || !o.label.trim()) return '--label is required: the name kept for this chat';
  if (!['me', 'both'].includes(o.from)) return '--from is me or both';
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(o.name)) return '--name is lower-case letters, digits and hyphens';
  if (GROUP.test(o.chat) && !o.allowGroup) return 'a group chat needs --allow-group';
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
 * The text messages of one chat sent after `sinceApple` (Core Data seconds)
 * and written to the database after row `afterPk`, in the order they were
 * written, as observations. The row is the watermark, not the time, so a
 * message that reaches this Mac late (synced from the phone) isn't missed. A
 * message with no text (media, a deleted message's tombstone) is skipped,
 * never read further.
 */
export function readMessages(db, { chat, label, from, isGroup }, sinceApple, afterPk = 0) {
  const rows = db.prepare(`
    SELECT m.Z_PK AS pk, m.ZISFROMME AS mine, m.ZMESSAGEDATE AS date, m.ZTEXT AS text, m.ZSTANZAID AS stanza
    FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
    WHERE s.ZCONTACTJID = ? AND m.ZMESSAGEDATE > ? AND m.Z_PK > ?
      AND m.ZTEXT IS NOT NULL AND m.ZTEXT <> ''
      ${from === 'me' ? 'AND m.ZISFROMME = 1' : ''}
    ORDER BY m.Z_PK
  `).all(chat, sinceApple, afterPk);
  // Who wrote it, by the label the person chose. In a group, members aren't named.
  const other = isGroup ? 'Member' : label;
  return rows.map((r) => ({
    pk: r.pk,
    observation: {
      at: new Date((r.date + APPLE_EPOCH_S) * 1000).toISOString(),
      kind: 'screen',
      app: 'WhatsApp',
      bundle: 'net.whatsapp.WhatsApp',
      window: `WhatsApp: ${label}`,
      text: `${r.mine ? 'Me' : other}: ${r.text}`,
      // A message's own id: a restarted sensor adds nothing, and a revoked message never comes back.
      dedupe: `wa:${r.stanza ?? `pk-${r.pk}`}`.slice(0, 200),
    },
  }));
}

/** JSON a line, with U+2028 and U+2029 escaped so a line ends at \n alone. */
export const line = (value) => `${JSON.stringify(value).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029')}\n`;

function listChats(db) {
  const rows = db.prepare(`
    SELECT s.ZCONTACTJID AS jid, COUNT(m.Z_PK) AS messages
    FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
    GROUP BY s.Z_PK ORDER BY messages DESC
  `).all();
  for (const r of rows) process.stderr.write(`${r.jid}\t${r.messages}${GROUP.test(r.jid ?? '') ? '\tgroup' : ''}\n`);
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
  const isGroup = GROUP.test(o.chat);
  const sinceApple = startFor(o) / 1000 - APPLE_EPOCH_S;
  let afterPk = 0;

  const poll = () => {
    // Opened and closed each time, so it never holds WhatsApp's database open between reads.
    let db;
    try {
      db = openReadOnly(o.db);
      const why = schemaError(db);
      if (why) {
        process.stderr.write(`stopped: not a WhatsApp database this sensor knows (${why})\n`);
        process.exit(1);
      }
      for (const { pk, observation } of readMessages(db, { chat: o.chat, label: o.label, from: o.from, isGroup }, sinceApple, afterPk)) {
        process.stdout.write(line(observation));
        afterPk = Math.max(afterPk, pk);
      }
    } catch (err) {
      // Unreadable (no permission yet, WhatsApp mid-write): try again next time, and say why on stderr.
      process.stderr.write(`could not read: ${err.message}\n`);
    } finally {
      db?.close();
    }
  };

  poll();
  if (!o.once) setInterval(poll, o.every * 1000);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
