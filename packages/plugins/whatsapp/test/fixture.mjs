/**
 * A synthetic WhatsApp Desktop database, built in a temporary folder for the
 * tests. Only the tables and columns the sensor reads, shaped as reported for
 * the Mac app (Core Data, ChatStorage.sqlite). Every name, number and message
 * here is made up: no real chat is, or should ever be, a fixture.
 */

import { mkdtempSync, rmSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { APPLE_EPOCH_S } from '../sensor.mjs';

// 555-01xx numbers are reserved for fiction.
export const CHAT_A = '15555550100@s.whatsapp.net';
export const CHAT_B = '15555550101@s.whatsapp.net';
export const GROUP = '120363000000000000@g.us';

const apple = (iso) => Date.parse(iso) / 1000 - APPLE_EPOCH_S;
/** A time this many hours before now, so the fixture never ages out of the tests. */
export const ago = (hours) => new Date(Date.now() - hours * 3_600_000).toISOString();

export const MESSAGES = [
  // chat, mine, at, text, stanza
  // History: older than a day, read only with --history-days or --since.
  [CHAT_A, 1, ago(24 * 40), 'Forty days ago, from me.', 'STANZA-H40'],
  [CHAT_A, 0, ago(24 * 10), 'Ten days ago, from them.', 'STANZA-H10'],
  // The last day.
  [CHAT_A, 1, ago(5), 'Morning, are we still on for the demo?', 'STANZA-A1'],
  [CHAT_A, 0, ago(4.9), 'Yes, 3pm works.', 'STANZA-A2'],
  [CHAT_A, 1, ago(4.8), 'Here is the staging key ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx', 'STANZA-A3'],
  [CHAT_A, 1, ago(4.7), null, 'STANZA-A4'], // a photo: no text
  [CHAT_B, 1, ago(4), 'Not on the list, never read.', 'STANZA-B1'],
  [GROUP, 1, ago(3), 'Group hello from me.', 'STANZA-G1'],
  [GROUP, 0, ago(2.9), 'Group hello from a member.', 'STANZA-G2'],
];

/** Builds the database; returns its path and a cleanup. */
export function buildFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'pc-whatsapp-'));
  const path = join(dir, 'ChatStorage.sqlite');
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec(`
    CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR, ZSESSIONTYPE INTEGER);
    CREATE TABLE ZWAMESSAGE (
      Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP,
      ZTEXT VARCHAR, ZSTANZAID VARCHAR, ZFROMJID VARCHAR, ZMESSAGETYPE INTEGER
    );
  `);
  const chats = [...new Set(MESSAGES.map((m) => m[0]))];
  const addChat = db.prepare('INSERT INTO ZWACHATSESSION (ZCONTACTJID, ZPARTNERNAME) VALUES (?, ?)');
  chats.forEach((jid, i) => addChat.run(jid, `Synthetic Contact ${i + 1}`));
  const pkOf = (jid) => chats.indexOf(jid) + 1;
  const add = db.prepare('INSERT INTO ZWAMESSAGE (ZCHATSESSION, ZISFROMME, ZMESSAGEDATE, ZTEXT, ZSTANZAID) VALUES (?, ?, ?, ?, ?)');
  for (const [jid, mine, at, text, stanza] of MESSAGES) add.run(pkOf(jid), mine, apple(at), text, stanza);
  db.close();
  return {
    path,
    /** Adds one message, as WhatsApp would when one arrives. */
    add(jid, mine, at, text, stanza) {
      const w = new DatabaseSync(path);
      w.prepare('INSERT INTO ZWAMESSAGE (ZCHATSESSION, ZISFROMME, ZMESSAGEDATE, ZTEXT, ZSTANZAID) VALUES (?, ?, ?, ?, ?)')
        .run(pkOf(jid), mine, apple(at), text, stanza);
      w.close();
    },
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}
