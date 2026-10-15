import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { startDriver } from '../driver-client.js';

// Addresses as a store made before the source_url rule kept them, and what migration 011 leaves.
const OLD = [
  ['https://zac:pw@app.example.com/reset?token=SECRETTOKEN#step', 'https://app.example.com/reset'],
  ['https://example.com/plain/path', 'https://example.com/plain/path'],
  ['data:text/plain,Confidential%20notes', null],
  ['data://text/plain,PRIVATE_NOTES', null],
  ['JavaScript://example.com/%0Aalert(1)', null],
  ['about:blank', null],
  ['?only=query', null],
  [`https://example.com/${'a'.repeat(3000)}`, `https://example.com/${'a'.repeat(2048 - 20)}`],
];

test('store: addresses kept before the source_url rule are cut to it when the store is opened', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-urls-'));
  const path = join(dir, 'store.sqlite');
  const key = randomBytes(32).toString('hex');
  try {
    let driver = startDriver();
    await driver.call('open', { path, master_key_hex: key });
    await driver.close();
    // As an earlier build left it: the addresses as given, and 011 not yet applied.
    const db = new DatabaseSync(path);
    OLD.forEach(([url], i) => db.prepare(`
      INSERT INTO capture_event (capture_id, sequence, captured_at, capture_type, source, source_url, privacy_level)
      VALUES (?, ?, '2026-10-01T09:00:00.000Z', 'screen_text', 'screen', ?, 'standard')`).run(`cap_old_${i}`, 1000 + i, url));
    db.prepare("DELETE FROM schema_migration WHERE name = '011_source_url_rule.sql'").run();
    db.close();

    driver = startDriver();
    await driver.call('open', { path, master_key_hex: key });
    await driver.close();
    const check = new DatabaseSync(path, { readOnly: true });
    const kept = OLD.map((_, i) => check.prepare('SELECT source_url FROM capture_event WHERE capture_id = ?').get(`cap_old_${i}`).source_url);
    const update = check.prepare("SELECT sql FROM sqlite_master WHERE name = 'capture_event_no_update'").get();
    check.close();
    assert.deepEqual(kept, OLD.map(([, after]) => after));
    assert.ok(update, 'the append-only trigger was not put back');
    // And still append-only.
    const again = new DatabaseSync(path);
    assert.throws(() => again.prepare("UPDATE capture_event SET source_url = 'x' WHERE capture_id = 'cap_old_1'").run(), /append-only/);
    again.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
