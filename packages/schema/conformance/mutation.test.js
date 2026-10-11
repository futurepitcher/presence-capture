/**
 * The forensic check is only worth something if it fails stores that do not
 * erase. Each mutant here is the reference store with one erasure step broken
 * from the outside, and each must produce at least one forensic failure.
 */

import assert from 'node:assert/strict';
import test from 'node:test';
import { forensicErasureCheck } from './forensic.js';
import { openStore } from '../src/store.js';

const mutant = (breakIt) => (path, options) => {
  const store = openStore(path, options);
  breakIt(store);
  return store;
};

// A trigger that RAISE(IGNORE)s skips the statement silently: the store thinks
// it deleted the row.
const ignoreDeletes = (table) => (store) => store.db.exec(`
  CREATE TEMP TRIGGER mutant_keep_${table} BEFORE DELETE ON main.${table}
  BEGIN SELECT RAISE(IGNORE); END;
`);

const MUTANTS = {
  'keys survive revocation': ignoreDeletes('capture_key'),
  'sealed text survives revocation': ignoreDeletes('capture_content'),
  'sealed payload survives revocation': ignoreDeletes('payload_blob'),
  'deleted pages are not overwritten': (store) => store.db.exec('PRAGMA secure_delete = OFF'),
  'write-ahead log is never truncated': (store) => {
    const exec = store.db.exec.bind(store.db);
    store.db.exec = (sql) => (sql.includes('wal_checkpoint') ? undefined : exec(sql));
  },
  'no erasure receipt is written': (store) => store.db.exec(`
    CREATE TEMP TRIGGER mutant_no_receipt BEFORE INSERT ON main.erasure_receipt
    BEGIN SELECT RAISE(IGNORE); END;
  `),
};

for (const [name, breakIt] of Object.entries(MUTANTS)) {
  test(`R11 mutant is caught: ${name}`, () => {
    const failures = forensicErasureCheck(mutant(breakIt));
    assert.ok(failures.length > 0, `a store where ${name} passed the forensic check`);
  });
}

test('R11: the unmutated store passes, so the mutants fail for their mutation', () => {
  assert.deepEqual(forensicErasureCheck(openStore), []);
});
