import assert from 'node:assert/strict';
import test from 'node:test';
import { FUTURE } from './helpers.js';
import { AuthorizationError, openStore } from '../src/store.js';

function storeWithLevels() {
  const store = openStore();
  for (const level of ['standard', 'sensitive', 'excluded', 'sacred_mode']) {
    store.appendCapture({
      captureType: 'screen_text',
      source: 'screen',
      privacyLevel: level,
      contentText: `content at ${level}`,
    });
  }
  return store;
}

test('T1: a client with no grant receives nothing, loudly', () => {
  const store = storeWithLevels();
  assert.throws(() => store.createReader('grn_does_not_exist'), AuthorizationError);
  store.close();
});

test('T2: sacred_mode is unreachable through any read path', () => {
  const store = storeWithLevels();
  const grantId = store.issueGrant({
    clientId: 'editor',
    expiresAt: FUTURE,
    privacyLevels: ['standard', 'sensitive', 'excluded'],
  });
  const rows = store.createReader(grantId).read({ tool: 'search', limit: 100 });
  const levels = rows.map((r) => r.presence_capture_untrusted.provenance.privacy_level);
  assert.ok(!levels.includes('sacred_mode'), 'sacred_mode content was served');
  store.close();
});

test('T4: a grant naming sacred_mode is not issuable at all', () => {
  const store = storeWithLevels();
  assert.throws(
    () => store.issueGrant({
      clientId: 'editor', expiresAt: FUTURE, privacyLevels: ['standard', 'sacred_mode'],
    }),
    /CHECK|constraint/i,
    'the store accepted a grant for sacred_mode',
  );
  store.close();
});

test('T4: sensitive and excluded are excluded unless the grant names them', () => {
  const store = storeWithLevels();
  const grantId = store.issueGrant({ clientId: 'editor', expiresAt: FUTURE }); // defaults
  const rows = store.createReader(grantId).read({ tool: 'search', limit: 100 });
  const levels = [...new Set(rows.map((r) => r.presence_capture_untrusted.provenance.privacy_level))];
  assert.deepEqual(levels, ['standard']);
  store.close();
});

test('T5: expired and revoked grants serve nothing', () => {
  const store = storeWithLevels();

  const expired = store.issueGrant({
    clientId: 'editor', expiresAt: '2020-01-01T00:00:00Z',
  });
  assert.throws(() => store.createReader(expired).read({ tool: 'search' }), /expired/);

  const live = store.issueGrant({ clientId: 'editor', expiresAt: FUTURE });
  store.revokeGrant(live);
  assert.throws(() => store.createReader(live).read({ tool: 'search' }), /revoked/);

  store.close();
});

test('T3: the grant caps row count even when a caller asks for more', () => {
  const store = openStore();
  for (let i = 0; i < 20; i += 1) {
    store.appendCapture({
      captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: `row ${i}`,
    });
  }
  const grantId = store.issueGrant({ clientId: 'editor', expiresAt: FUTURE, maxRowsPerQuery: 3 });
  const rows = store.createReader(grantId).read({ tool: 'search', limit: 1000 });
  assert.equal(rows.length, 3, 'a caller talked its way past max_rows_per_query');
  store.close();
});

test('T3: revoked captures are filtered out below the tool layer', () => {
  const store = openStore();
  const id = store.appendCapture({
    captureType: 'screen_text', source: 'screen', privacyLevel: 'standard', contentText: 'secret',
  });
  const grantId = store.issueGrant({ clientId: 'editor', expiresAt: FUTURE });
  assert.equal(store.createReader(grantId).read({ tool: 'search' }).length, 1);

  store.revoke({ scopeKind: 'capture', scopeValue: id });
  assert.equal(store.createReader(grantId).read({ tool: 'search' }).length, 0);
  store.close();
});

test('a grant with no expiry is not issuable', () => {
  const store = openStore();
  assert.throws(() => store.issueGrant({ clientId: 'editor' }), /no expiry/);
  store.close();
});
