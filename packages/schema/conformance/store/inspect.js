/**
 * Reading a store's files as SCHEMA.md defines them, with no help from the
 * implementation that wrote them. This is what makes the store layer
 * implementation-neutral: if these reads work on your store, so does the
 * suite.
 */

import { createDecipheriv } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

/** Every file under dir, recursively, so blob directories are scanned too. */
export function filesUnder(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? filesUnder(path) : [path];
  });
}

/** Run one read against the store file and close. */
export function query(path, sql, ...params) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    return db.prepare(sql).all(...params);
  } finally {
    db.close();
  }
}

/** AES-256-GCM, combined form nonce(12) || ciphertext || tag(16). Null when it does not open. */
export function unsealPerSpec(key, sealed, aad) {
  try {
    const bytes = Buffer.from(sealed);
    const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
    decipher.setAAD(Buffer.from(aad));
    decipher.setAuthTag(bytes.subarray(bytes.length - 16));
    return Buffer.concat([decipher.update(bytes.subarray(12, bytes.length - 16)), decipher.final()]);
  } catch {
    return null;
  }
}

/**
 * A capture's sealed payload, wherever the store keeps it: a payload_blob row,
 * or a file named by storage_uri 'file:<path relative to the store directory>'.
 */
function sealedPayload(db, dir, captureId) {
  const row = db.prepare(`
    SELECT p.storage_uri, b.sealed FROM capture_event e
    JOIN capture_payload p ON p.payload_hash = e.payload_hash
    LEFT JOIN payload_blob b ON b.payload_hash = e.payload_hash
    WHERE e.capture_id = ?
  `).get(captureId);
  if (!row) return null;
  if (row.sealed) return Buffer.from(row.sealed);
  if (row.storage_uri?.startsWith('file:')) {
    const file = join(dir, row.storage_uri.slice('file:'.length));
    return existsSync(file) ? readFileSync(file) : null;
  }
  return null;
}

/** The wrapped keys, sealed text and sealed payloads of the given captures, labelled. */
export function sealedArtifacts(path, dir, captureIds) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const out = [];
    for (const id of captureIds) {
      const key = db.prepare('SELECT wrapped_key FROM capture_key WHERE capture_id = ?').get(id);
      if (key) out.push([`wrapped key of ${id}`, Buffer.from(key.wrapped_key)]);
      const text = db.prepare('SELECT text_sealed FROM capture_content WHERE capture_id = ?').get(id);
      if (text) out.push([`sealed text of ${id}`, Buffer.from(text.text_sealed)]);
      const payload = sealedPayload(db, dir, id);
      if (payload) out.push([`sealed payload of ${id}`, payload]);
      for (const row of db.prepare('SELECT entry_ref, output_sealed FROM projection_entry WHERE capture_id = ? AND output_sealed IS NOT NULL').all(id)) {
        out.push([`sealed projection output ${row.entry_ref} of ${id}`, Buffer.from(row.output_sealed)]);
      }
    }
    return out;
  } finally {
    db.close();
  }
}

/**
 * Everything the holder of the directory *and* the master key can still read,
 * plus the erasure receipt for one revocation.
 */
export function recoverable(path, dir, masterKey, revocationId) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const texts = [];
    for (const { capture_id: id, wrapped_key: wrapped } of db.prepare('SELECT capture_id, wrapped_key FROM capture_key').all()) {
      const key = unsealPerSpec(masterKey, wrapped, `key:${id}`);
      if (!key) continue;
      const text = db.prepare('SELECT text_sealed FROM capture_content WHERE capture_id = ?').get(id);
      const opened = text && unsealPerSpec(key, text.text_sealed, `text:${id}`);
      if (opened) texts.push(opened.toString('utf8'));
      const payload = sealedPayload(db, dir, id);
      const bytes = payload && unsealPerSpec(key, payload, `payload:${id}`);
      if (bytes) texts.push(bytes.toString('utf8'));
      for (const row of db.prepare('SELECT projection_name, entry_ref, output_sealed FROM projection_entry WHERE capture_id = ? AND output_sealed IS NOT NULL').all(id)) {
        const output = unsealPerSpec(key, row.output_sealed, `projection:${row.projection_name}:${id}:${row.entry_ref}`);
        if (output) texts.push(output.toString('utf8'));
      }
    }
    const receipt = db.prepare('SELECT * FROM erasure_receipt WHERE revocation_id = ?').get(revocationId);
    return { texts, receipt };
  } finally {
    db.close();
  }
}
