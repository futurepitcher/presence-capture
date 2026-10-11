import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { filesUnder, sealedArtifacts } from './inspect.js';
import { screenText, withStore } from './helpers.js';

const holds = (dir, secrets) => filesUnder(dir).some((file) => {
  const bytes = readFileSync(file);
  return secrets.some(([, secret]) => bytes.indexOf(secret) !== -1);
});

test('store R11: a reader holding the log delays erasure, which is not reported done until it is', () => withStore(async ({ call, path, dir }) => {
  const { capture_id: id } = await call('append', screenText('read while being forgotten'));
  const secrets = sealedArtifacts(path, dir, [id]);

  // Another process (an MCP server, say) mid-read: its snapshot keeps the
  // write-ahead log from being truncated.
  const reader = new DatabaseSync(path, { readOnly: true });
  reader.exec('BEGIN');
  reader.prepare('SELECT COUNT(*) FROM capture_event').get();

  const revoked = await call('revoke', { scope_kind: 'capture', scope_value: id });
  assert.equal(revoked.erased_on_disk, false, 'reported erased while the log still held the revoked bytes');
  assert.ok(holds(dir, secrets), 'the scenario did not hold the log: this test proves nothing');

  reader.exec('COMMIT');
  reader.close();

  // Once the reader lets go, the next revocation folds the log in and truncates it.
  const next = await call('revoke', { scope_kind: 'capture', scope_value: 'cap_nothing' });
  assert.equal(next.erased_on_disk, true);
  assert.ok(!holds(dir, secrets), 'revoked bytes survived in the log after it could be truncated');
}));

test('store R11: with no reader in the way, a revocation reports its erasure done', () => withStore(async ({ call }) => {
  const { capture_id: id } = await call('append', screenText('x'));
  assert.equal((await call('revoke', { scope_kind: 'capture', scope_value: id })).erased_on_disk, true);
}));
