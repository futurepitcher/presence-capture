/**
 * The forensic check is only worth something if it fails stores that do not
 * erase. Each mutant is the reference store with one erasure step broken from
 * the outside, driven through the same protocol, and each must produce at
 * least one forensic failure.
 *
 * This file tests the check, not an implementation, so it always runs against
 * the reference store, whatever PRESENCE_CAPTURE_DRIVER says.
 */

import assert from 'node:assert/strict';
import test from 'node:test';
import { createDriverHandler } from '../../src/driver.js';
import { openStore } from '../../src/store.js';
import { inProcessDriver } from '../driver-client.js';
import { forensicErasureCheck } from './forensic.js';

const driverFor = (breakIt) => () => inProcessDriver(createDriverHandler({
  open: (path, options) => {
    const store = openStore(path, options);
    breakIt(store);
    return store;
  },
}));

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
  test(`R11 mutant is caught: ${name}`, async () => {
    const failures = await forensicErasureCheck(driverFor(breakIt));
    assert.ok(failures.length > 0, `a store where ${name} passed the forensic check`);
    assert.ok(
      failures.every((f) => !f.startsWith('check could not run')),
      `the check crashed rather than finding the mutation: ${failures}`,
    );
  });
}

test('R11: the unmutated store passes in-process too, so each mutant fails for its mutation', async () => {
  assert.deepEqual(await forensicErasureCheck(driverFor(() => {})), []);
});
