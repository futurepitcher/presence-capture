import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { sessionsOf } from '../../src/sessions.js';

const { cases } = JSON.parse(readFileSync(new URL('../../cases/sessions.json', import.meta.url), 'utf8'));

for (const c of cases) {
  test(`sessions: ${c.why}`, () => {
    assert.deepEqual(sessionsOf(c.activity, { now: c.now }), c.sessions);
  });
}
