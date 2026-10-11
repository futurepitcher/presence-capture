import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startDriver } from '../driver-client.js';

/**
 * Run fn against a fresh store in its own directory, opened through the
 * driver with a master key the test holds.
 */
export async function withStore(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'pc-store-'));
  const path = join(dir, 'store.sqlite');
  const masterKey = randomBytes(32);
  const driver = startDriver();
  try {
    await driver.call('open', { path, master_key_hex: masterKey.toString('hex') });
    return await fn({ call: driver.call, path, dir, masterKey });
  } finally {
    await driver.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

/** A screen-text capture; extra fields override. */
export const screenText = (text, extra = {}) => ({
  capture_type: 'screen_text', source: 'screen', privacy_level: 'standard',
  content_text: text, extraction: 'ocr', ...extra,
});

/** Append an audio segment, its transcript and an alignment of the transcript (R10). */
export async function appendAudioChain(call) {
  const { capture_id: audio } = await call('append', {
    capture_type: 'audio_segment', source: 'ambient_audio', privacy_level: 'standard',
    payload: { bytes_base64: Buffer.from('audio').toString('base64'), media_type: 'audio/wav' },
  });
  const { capture_id: transcript } = await call('append', {
    capture_type: 'audio_transcript', source: 'ambient_audio', privacy_level: 'standard',
    content_text: 'we agreed to ship on friday', extraction: 'asr', derived_from: audio,
  });
  const { capture_id: alignment } = await call('append', {
    capture_type: 'audio_alignment', source: 'ambient_audio', privacy_level: 'standard',
    derived_from: transcript,
  });
  return { audio, transcript, alignment };
}
