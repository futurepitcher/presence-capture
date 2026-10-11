import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

/**
 * AES-256-GCM in the combined form SCHEMA.md defines: nonce(12) || ciphertext
 * || tag(16). The same layout as CryptoKit's `AES.GCM.SealedBox.combined`, so
 * a store written by the Swift daemon opens here and the other way round.
 *
 * `aad` binds a sealed value to the capture it belongs to.
 */
export function seal(key, plaintext, aad) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.from(aad));
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([nonce, body, cipher.getAuthTag()]);
}

/** Throws when the key, the AAD or the bytes are wrong. */
export function unseal(key, sealed, aad) {
  const bytes = Buffer.from(sealed);
  const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
  decipher.setAAD(Buffer.from(aad));
  decipher.setAuthTag(bytes.subarray(bytes.length - 16));
  return Buffer.concat([decipher.update(bytes.subarray(12, bytes.length - 16)), decipher.final()]);
}

export const newKey = () => randomBytes(32);
