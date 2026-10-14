import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { openStore } from '../../src/store.js';

/** Another process mid-read: its snapshot keeps the write-ahead log from being truncated. */
function pinLog(path) {
  const reader = new DatabaseSync(path, { readOnly: true });
  reader.exec('BEGIN');
  reader.prepare('SELECT COUNT(*) FROM capture_event').get();
  return () => {
    reader.exec('COMMIT');
    reader.close();
  };
}

test('R11: a writer stamps only the erasures its truncation proved, never one another writer commits after it', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-stamp-'));
  const path = join(dir, 'store.sqlite');
  const masterKey = randomBytes(32);
  const completedAt = (db, rev) => db.prepare('SELECT completed_at FROM erasure_receipt WHERE revocation_id = ?').get(rev).completed_at;
  try {
    let between = () => {};
    const a = openStore(path, { masterKey, onTruncated: () => between() });
    const b = openStore(path, { masterKey });
    const first = a.appendCapture({ captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'first' });
    const second = a.appendCapture({ captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'second' });

    let release = pinLog(path);
    const { revocationId: revA } = a.revoke({ scopeKind: 'capture', scopeValue: first });
    release();

    // After A's truncation and before it stamps: B revokes while another reader holds the log.
    let revB;
    between = () => {
      between = () => {};
      release = pinLog(path);
      ({ revocationId: revB } = b.revoke({ scopeKind: 'capture', scopeValue: second }));
    };
    a.finishErasure();
    assert.ok(completedAt(a.db, revA), "A's erasure, which its truncation proved, wasn't stamped");
    assert.equal(completedAt(a.db, revB), null, "B's erasure was stamped done by a truncation that came before it");

    release();
    assert.equal(b.finishErasure(), true);
    assert.ok(completedAt(a.db, revB));
    a.close();
    b.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('R11: a failure finishing the erasure after the revocation committed says so, and the revocation stands', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-after-'));
  const path = join(dir, 'store.sqlite');
  try {
    let fail = true;
    const store = openStore(path, { masterKey: randomBytes(32), onTruncated: () => { if (fail) throw new Error('disk full'); } });
    const id = store.appendCapture({ captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'forgotten' });

    const result = store.revoke({ scopeKind: 'capture', scopeValue: id });
    assert.deepEqual(result.revokedCaptureIds, [id]);
    assert.equal(result.erasedOnDisk, false);
    assert.match(result.erasureError, /disk full/);
    assert.equal(store.contentText(id), null, 'the revocation did not stand');
    assert.equal(store.erasurePending, true);

    fail = false;
    assert.equal(store.finishErasure(), true);
    store.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
