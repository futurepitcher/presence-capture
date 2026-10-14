import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startDriver } from '../driver-client.js';
import { filesUnder, query, sealedArtifacts } from './inspect.js';
import { screenText, withStore } from './helpers.js';

const completedAt = (path, revocationId) =>
  query(path, 'SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?', revocationId)[0].completed_at;

/** Another process (an MCP server, say) mid-read: its snapshot keeps the write-ahead log from being truncated. */
function pinLog(path) {
  const reader = new DatabaseSync(path, { readOnly: true });
  reader.exec('BEGIN');
  reader.prepare('SELECT COUNT(*) FROM capture_event').get();
  return () => {
    reader.exec('COMMIT');
    reader.close();
  };
}

const holds = (dir, secrets) => filesUnder(dir).some((file) => {
  const bytes = readFileSync(file);
  return secrets.some(([, secret]) => bytes.indexOf(secret) !== -1);
});

test('store R11: a reader holding the log delays erasure, which is not reported done until it is', () => withStore(async ({ call, path, dir }) => {
  const { capture_id: id } = await call('append', screenText('read while being forgotten'));
  const secrets = sealedArtifacts(path, dir, [id]);

  const release = pinLog(path);
  const revoked = await call('revoke', { scope_kind: 'capture', scope_value: id });
  assert.equal(revoked.erased_on_disk, false, 'reported erased while the log still held the revoked bytes');
  assert.ok(holds(dir, secrets), 'the scenario did not hold the log: this test proves nothing');
  assert.equal(completedAt(path, revoked.revocation_id), null, 'the receipt says the erasure is complete while the log holds it');
  release();

  // Once the reader lets go, the next revocation folds the log in and truncates it.
  const next = await call('revoke', { scope_kind: 'capture', scope_value: 'cap_nothing' });
  assert.equal(next.erased_on_disk, true);
  assert.ok(!holds(dir, secrets), 'revoked bytes survived in the log after it could be truncated');
  assert.ok(completedAt(path, revoked.revocation_id), 'the held-up erasure was finished but its receipt never says so');
}));

test('store R11: an erasure held up when its writer exits is finished by the next writer to open the store', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-store-'));
  const path = join(dir, 'store.sqlite');
  const masterKey = randomBytes(32).toString('hex');
  try {
    // A command-line Forget: it revokes while a reader holds the log, and exits.
    const first = startDriver();
    await first.call('open', { path, master_key_hex: masterKey });
    const { capture_id: id } = await first.call('append', screenText('forgotten by a process that then exited'));
    const secrets = sealedArtifacts(path, dir, [id]);
    const release = pinLog(path);
    const { revocation_id: rev, erased_on_disk: erased } = await first.call('revoke', { scope_kind: 'capture', scope_value: id });
    assert.equal(erased, false);
    await first.close();
    assert.ok(holds(dir, secrets), 'the scenario did not hold the log: this test proves nothing');
    assert.equal(completedAt(path, rev), null);
    release();

    // The next writer to open the store (the app at its next launch) finishes it, unasked.
    const next = startDriver();
    await next.call('open', { path, master_key_hex: masterKey });
    try {
      assert.ok(completedAt(path, rev), 'a pending erasure was left pending by a writer that opened the store');
      assert.ok(!holds(dir, secrets), 'revoked bytes survived after a writer opened the store with nothing holding the log');
    } finally {
      await next.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('store R11: with no reader in the way, a revocation reports its erasure done, and its receipt says when', () => withStore(async ({ call, path }) => {
  const { capture_id: id } = await call('append', screenText('x'));
  const revoked = await call('revoke', { scope_kind: 'capture', scope_value: id });
  assert.equal(revoked.erased_on_disk, true);
  assert.ok(completedAt(path, revoked.revocation_id));
}));

test('store R11: an erasure receipt is append-only but for its completion, stamped once', () => withStore(async ({ call, path }) => {
  const { capture_id: id } = await call('append', screenText('x'));
  const { revocation_id: rev } = await call('revoke', { scope_kind: 'capture', scope_value: id });
  const db = new DatabaseSync(path);
  try {
    assert.throws(() => db.prepare('UPDATE erasure_receipt SET completed_at = ? WHERE revocation_id = ?').run('2099-01-01T00:00:00.000Z', rev));
    assert.throws(() => db.prepare('UPDATE erasure_receipt SET keys_destroyed = 0 WHERE revocation_id = ?').run(rev));
    assert.throws(() => db.prepare('DELETE FROM erasure_receipt WHERE revocation_id = ?').run(rev));
  } finally {
    db.close();
  }
}));
