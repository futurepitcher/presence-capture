import assert from 'node:assert/strict';
import test from 'node:test';
import { forensicErasureCheck } from './forensic.js';
import { openStore } from '../src/store.js';

test('R11: revoked content is gone from every byte on disk, and cannot be decrypted', () => {
  assert.deepEqual(forensicErasureCheck(openStore), []);
});
