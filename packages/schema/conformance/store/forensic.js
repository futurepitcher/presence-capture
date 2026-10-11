/**
 * Forensic erasure check (R11).
 *
 * Revocation is only a claim until someone looks at the disk. This check
 * drives an implementation through the driver protocol against a real
 * directory, revokes an audio capture (and through R10 its transcript), then
 * reads every file the store left behind, byte by byte, the way someone
 * holding a copy of the directory would.
 *
 * It returns a list of failures rather than asserting, so the mutation suite
 * can require that a deliberately broken store produces at least one.
 */

import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { filesUnder, recoverable, sealedArtifacts } from './inspect.js';

// Distinctive enough that a chance match in SQLite's own bytes is impossible.
export const MARKERS = {
  transcript: 'pc-forensic-transcript-7f3a9c2e',
  payload: 'pc-forensic-payload-b81d44f0',
  control: 'pc-forensic-control-5e6c1a93',
};

const contains = (haystack, needle) => needle.length > 0 && haystack.indexOf(needle) !== -1;

/**
 * @param {() => {call: (op: string, args?: object) => Promise<object>, close: () => Promise<void>}} start
 *   starts a driver client
 * @returns {Promise<string[]>} failures; empty when the store erased what it revoked
 */
export async function forensicErasureCheck(start) {
  const dir = mkdtempSync(join(tmpdir(), 'pc-forensic-'));
  const path = join(dir, 'store.sqlite');
  const masterKey = randomBytes(32);
  const driver = start();
  const failures = [];
  const relative = (file) => file.slice(dir.length + 1);

  try {
    await driver.call('open', { path, master_key_hex: masterKey.toString('hex') });
    await driver.call('register_projection', { name: 'text_index', kind: 'index' });

    const { capture_id: audioId } = await driver.call('append', {
      capture_type: 'audio_segment', source: 'ambient_audio', privacy_level: 'standard',
      payload: { bytes_base64: Buffer.from(MARKERS.payload).toString('base64'), media_type: 'audio/wav' },
    });
    const { capture_id: transcriptId } = await driver.call('append', {
      capture_type: 'audio_transcript', source: 'ambient_audio', privacy_level: 'standard',
      content_text: MARKERS.transcript, extraction: 'asr', derived_from: audioId,
    });
    const { capture_id: controlId } = await driver.call('append', {
      capture_type: 'screen_text', source: 'screen', privacy_level: 'standard',
      content_text: MARKERS.control, extraction: 'ocr',
    });
    await driver.call('add_projection_entry', { projection: 'text_index', capture_id: transcriptId, entry_ref: 'fts:1' });
    await driver.call('add_projection_entry', { projection: 'text_index', capture_id: controlId, entry_ref: 'fts:2' });

    // Plaintext must never reach the disk, revoked or not (CONTRACT: redact,
    // then seal, then write).
    for (const file of filesUnder(dir)) {
      const bytes = readFileSync(file);
      for (const [name, marker] of Object.entries(MARKERS)) {
        if (contains(bytes, Buffer.from(marker))) {
          failures.push(`plaintext ${name} found on disk in ${relative(file)} before revocation`);
        }
      }
    }
    if (failures.length > 0) return failures;

    // What someone would look for afterwards: the wrapped keys and sealed
    // bytes of the captures about to be revoked.
    const secrets = sealedArtifacts(path, dir, [audioId, transcriptId]);
    if (secrets.length !== 4) {
      failures.push(`expected 4 sealed artifacts before revocation (2 keys, text, payload), found ${secrets.length}`);
    }

    const { revocation_id: revocationId } = await driver.call('revoke', {
      scope_kind: 'capture', scope_value: audioId, reason: 'forensic',
    });

    // Checked while the store is still open: a store must not rely on being
    // closed cleanly to erase.
    for (const file of filesUnder(dir)) {
      const bytes = readFileSync(file);
      for (const [label, secret] of secrets) {
        if (contains(bytes, secret)) failures.push(`${label} survived revocation in ${relative(file)}`);
      }
    }

    const { texts, receipt } = recoverable(path, dir, masterKey, revocationId);
    if (texts.some((t) => t.includes(MARKERS.transcript))) failures.push('revoked transcript still decrypts with the master key');
    if (texts.some((t) => t.includes(MARKERS.payload))) failures.push('revoked payload still decrypts with the master key');
    // Without this the check would pass a store that erased everything.
    if (!texts.some((t) => t.includes(MARKERS.control))) failures.push('unrevoked control capture is no longer recoverable');

    if (!receipt) failures.push('no erasure_receipt for the revocation');
    else if (receipt.keys_destroyed !== 2) failures.push(`erasure_receipt.keys_destroyed = ${receipt.keys_destroyed}, expected 2`);
  } catch (err) {
    failures.push(`check could not run: ${err.message}`);
  } finally {
    await driver.close();
    rmSync(dir, { recursive: true, force: true });
  }

  return failures;
}
