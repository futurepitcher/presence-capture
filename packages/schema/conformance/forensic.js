/**
 * Forensic erasure check (R11).
 *
 * Revocation is only a claim until someone looks at the disk. This check runs
 * a store against a real directory, revokes an audio capture (and through R10
 * its transcript), then reads every file the store left behind, byte by byte,
 * the way someone holding a copy of the directory would.
 *
 * It returns a list of failures rather than asserting, so the mutation suite
 * can require that a deliberately broken store produces at least one.
 */

import { createDecipheriv, randomBytes } from 'node:crypto';
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

// Distinctive enough that a chance match in SQLite's own bytes is impossible.
export const MARKERS = {
  transcript: 'pc-forensic-transcript-7f3a9c2e',
  payload: 'pc-forensic-payload-b81d44f0',
  control: 'pc-forensic-control-5e6c1a93',
};

/** Every file under dir, recursively, so blob directories are scanned too. */
function filesUnder(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? filesUnder(path) : [path];
  });
}

const containsBytes = (haystack, needle) => needle.length > 0 && haystack.indexOf(needle) !== -1;

/** AES-256-GCM, sealed as nonce(12) || ciphertext || tag(16), as SCHEMA.md defines. */
function tryOpen(key, sealed, aad) {
  try {
    const decipher = createDecipheriv('aes-256-gcm', key, sealed.subarray(0, 12));
    decipher.setAAD(Buffer.from(aad));
    decipher.setAuthTag(sealed.subarray(sealed.length - 16));
    return Buffer.concat([decipher.update(sealed.subarray(12, sealed.length - 16)), decipher.final()]);
  } catch {
    return null;
  }
}

/**
 * Everything the holder of the directory *and* the master key can still read.
 * After an erasure, the revoked markers must not be among it.
 */
function recoverable(dbPath, masterKey) {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const keys = new Map();
    for (const row of db.prepare('SELECT capture_id, wrapped_key FROM capture_key').all()) {
      const key = tryOpen(masterKey, Buffer.from(row.wrapped_key), `key:${row.capture_id}`);
      if (key) keys.set(row.capture_id, key);
    }
    const out = [];
    for (const row of db.prepare('SELECT capture_id, text_sealed FROM capture_content').all()) {
      const key = keys.get(row.capture_id);
      const text = key && row.text_sealed && tryOpen(key, Buffer.from(row.text_sealed), `text:${row.capture_id}`);
      if (text) out.push(text.toString('utf8'));
    }
    for (const row of db.prepare(`
      SELECT e.capture_id, b.sealed FROM payload_blob b
      JOIN capture_event e ON e.payload_hash = b.payload_hash
    `).all()) {
      const key = keys.get(row.capture_id);
      const bytes = key && tryOpen(key, Buffer.from(row.sealed), `payload:${row.capture_id}`);
      if (bytes) out.push(bytes.toString('utf8'));
    }
    return out;
  } finally {
    db.close();
  }
}

/**
 * @param {(path: string, options: {masterKey: Buffer}) => object} openStore
 * @returns {string[]} failures; empty when the store erased what it revoked
 */
export function forensicErasureCheck(openStore) {
  const dir = mkdtempSync(join(tmpdir(), 'pc-forensic-'));
  const dbPath = join(dir, 'store.sqlite');
  const masterKey = randomBytes(32);
  const failures = [];

  try {
    const store = openStore(dbPath, { masterKey });
    store.registerProjection({ name: 'text_index', kind: 'index' });

    const audioId = store.appendCapture({
      captureType: 'audio_segment', source: 'ambient_audio', privacyLevel: 'standard',
      payload: { bytes: Buffer.from(MARKERS.payload), mediaType: 'audio/wav' },
    });
    const transcriptId = store.appendCapture({
      captureType: 'audio_transcript', source: 'ambient_audio', privacyLevel: 'standard',
      contentText: MARKERS.transcript, extraction: 'asr', derivedFrom: audioId,
    });
    const controlId = store.appendCapture({
      captureType: 'screen_text', source: 'screen', privacyLevel: 'standard',
      contentText: MARKERS.control, extraction: 'ocr',
    });
    store.addProjectionEntry({ projection: 'text_index', captureId: transcriptId, entryRef: 'fts:1' });
    store.addProjectionEntry({ projection: 'text_index', captureId: controlId, entryRef: 'fts:2' });

    // Plaintext must never reach the disk, revoked or not (CONTRACT: redact,
    // then encrypt, then write).
    for (const file of filesUnder(dir)) {
      const bytes = readFileSync(file);
      for (const [name, marker] of Object.entries(MARKERS)) {
        if (containsBytes(bytes, Buffer.from(marker))) {
          failures.push(`plaintext ${name} found on disk in ${file.slice(dir.length + 1)} before revocation`);
        }
      }
    }
    if (failures.length > 0) {
      store.close();
      return failures;
    }

    // What an attacker would look for afterwards: the wrapped keys and sealed
    // bytes of the captures about to be revoked.
    const raw = new DatabaseSync(dbPath, { readOnly: true });
    const secrets = [
      ...raw.prepare('SELECT capture_id, wrapped_key AS b FROM capture_key WHERE capture_id IN (?, ?)')
        .all(audioId, transcriptId).map((r) => [`wrapped key of ${r.capture_id}`, Buffer.from(r.b)]),
      ...raw.prepare('SELECT capture_id, text_sealed AS b FROM capture_content WHERE capture_id = ?')
        .all(transcriptId).map((r) => ['sealed transcript text', Buffer.from(r.b)]),
      ...raw.prepare(`
        SELECT b.sealed AS b FROM payload_blob b
        JOIN capture_event e ON e.payload_hash = b.payload_hash WHERE e.capture_id = ?
      `).all(audioId).map((r) => ['sealed audio payload', Buffer.from(r.b)]),
    ];
    raw.close();
    if (secrets.length !== 4) {
      failures.push(`expected 4 sealed artifacts before revocation, found ${secrets.length}`);
    }

    const { revocationId } = store.revoke({ scopeKind: 'capture', scopeValue: audioId, reason: 'forensic' });

    // Checked while the store is still open: a store must not rely on being
    // closed cleanly to erase.
    for (const file of filesUnder(dir)) {
      const bytes = readFileSync(file);
      for (const [label, secret] of secrets) {
        if (containsBytes(bytes, secret)) {
          failures.push(`${label} survived revocation in ${file.slice(dir.length + 1)}`);
        }
      }
    }

    const left = recoverable(dbPath, masterKey);
    if (left.some((t) => t.includes(MARKERS.transcript))) failures.push('revoked transcript still decrypts with the master key');
    if (left.some((t) => t.includes(MARKERS.payload))) failures.push('revoked payload still decrypts with the master key');
    // Without this the check would pass a store that erased everything.
    if (!left.some((t) => t.includes(MARKERS.control))) failures.push('unrevoked control capture is no longer recoverable');

    const receipt = store.db
      .prepare('SELECT * FROM erasure_receipt WHERE revocation_id = ?')
      .get(revocationId);
    if (!receipt) failures.push('no erasure_receipt for the revocation');
    else if (receipt.keys_destroyed !== 2) failures.push(`erasure_receipt.keys_destroyed = ${receipt.keys_destroyed}, expected 2`);

    store.close();
  } catch (err) {
    failures.push(`check could not run: ${err.message}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  return failures;
}
