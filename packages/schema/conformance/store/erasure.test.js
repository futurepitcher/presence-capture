import assert from 'node:assert/strict';
import test from 'node:test';
import { startDriver } from '../driver-client.js';
import { forensicErasureCheck } from './forensic.js';

test('store R11: revoked content is gone from every byte on disk, and cannot be decrypted', async () => {
  assert.deepEqual(await forensicErasureCheck(() => startDriver()), []);
});
