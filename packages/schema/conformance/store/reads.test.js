import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { egressChainError, query } from './inspect.js';
import { screenText, withStore } from './helpers.js';

// Reads by id and of projection outputs (ADR 0008): how a ranked result is
// served, and how a reader finds an embedding written after its capture.

const FUTURE = '2099-01-01T00:00:00.000Z';
const ids = (envelopes) => envelopes.map((e) => e.presence_capture_untrusted.provenance.capture_id);

test('store ADR 0001: captures read by id come in the order asked, through the grant, each served once and logged', () => withStore(async ({ call, path }) => {
  const { capture_id: a } = await call('append', screenText('first'));
  const { capture_id: b } = await call('append', screenText('second'));
  const { capture_id: secret } = await call('append', screenText('private', { privacy_level: 'sensitive' }));
  const { capture_id: gone } = await call('append', screenText('forgotten'));
  await call('revoke', { scope_kind: 'capture', scope_value: gone });
  const { grant_id: grant } = await call('issue_grant', { client_id: 'agent', expires_at: FUTURE });

  const { envelopes } = await call('read_ids', { grant_id: grant, tool: 'search', query: 'ranked', capture_ids: [b, secret, gone, a, b, 'cap_unknown'] });
  assert.deepEqual(ids(envelopes), [b, a], 'not the order asked, or served what the grant or a revocation excludes');
  assert.deepEqual(envelopes.map((e) => e.presence_capture_untrusted.content), ['second', 'first']);

  const [record] = query(path, 'SELECT tool, capture_ids, row_count FROM egress_record ORDER BY egress_id DESC LIMIT 1');
  assert.deepEqual({ ...record, capture_ids: JSON.parse(record.capture_ids) }, { tool: 'search', capture_ids: [b, a], row_count: 2 });
  assert.equal(egressChainError(path), null);
}));

test('store ADR 0001: a read by id serves no more than the grant allows', () => withStore(async ({ call }) => {
  const many = [];
  for (let i = 0; i < 4; i++) many.push((await call('append', screenText(`n${i}`))).capture_id);
  const { grant_id: grant } = await call('issue_grant', { client_id: 'agent', expires_at: FUTURE, max_rows_per_query: 2 });
  assert.deepEqual(ids((await call('read_ids', { grant_id: grant, tool: 'search', capture_ids: many })).envelopes), many.slice(0, 2));
  await assert.rejects(call('read_ids', { grant_id: grant, tool: 'search', capture_ids: 'not a list' }), { code: 'bad_request' });
}));

test('store ADR 0008: outputs are read in the order written, so one written after its capture is found by its cursor', () => withStore(async ({ call }) => {
  await call('register_projection', { name: 'embeddings', kind: 'vector' });
  const { capture_id: a } = await call('append', screenText('embedded first'));
  const { capture_id: b } = await call('append', screenText('embedded later'));
  const { grant_id: grant } = await call('issue_grant', { client_id: 'agent', expires_at: FUTURE });
  await call('add_projection_entry', { projection: 'embeddings', capture_id: a, entry_ref: 'v:0', output_kind: 'vector', output_json: '[0.25,-1]' });

  const first = (await call('read_outputs', { grant_id: grant, tool: 'index', kind: 'vector' })).envelopes;
  assert.deepEqual(ids(first), [a]);
  const [{ presence_capture_untrusted: { provenance, content } }] = first;
  assert.deepEqual(JSON.parse(content), [0.25, -1]);
  assert.equal(provenance.projection, 'embeddings');
  assert.equal(provenance.entry_ref, 'v:0');
  assert.equal(provenance.output_kind, 'vector');
  const cursor = provenance.output_sequence;
  assert.ok(Number.isInteger(cursor));

  // A capture appended after, then its output: the output's number is past the cursor.
  await call('append', screenText('appended between'));
  await call('add_projection_entry', { projection: 'embeddings', capture_id: b, entry_ref: 'v:0', output_kind: 'vector', output_json: '[1,0]' });
  const next = (await call('read_outputs', { grant_id: grant, tool: 'index', kind: 'vector', after_output_sequence: cursor })).envelopes;
  assert.deepEqual(ids(next), [b]);
  assert.ok(next[0].presence_capture_untrusted.provenance.output_sequence > cursor);
}));

test('store ADR 0008: outputs of a capture the grant excludes, or a revoked one, are never read', () => withStore(async ({ call }) => {
  await call('register_projection', { name: 'embeddings', kind: 'vector' });
  const { capture_id: open } = await call('append', screenText('open'));
  const { capture_id: secret } = await call('append', screenText('secret', { privacy_level: 'sensitive' }));
  const { capture_id: gone } = await call('append', screenText('gone'));
  for (const id of [open, secret, gone]) {
    await call('add_projection_entry', { projection: 'embeddings', capture_id: id, entry_ref: 'v:0', output_kind: 'vector', output_json: '[1]' });
  }
  await call('revoke', { scope_kind: 'capture', scope_value: gone });
  const { grant_id: grant } = await call('issue_grant', { client_id: 'agent', expires_at: FUTURE });
  assert.deepEqual(ids((await call('read_outputs', { grant_id: grant, tool: 'index' })).envelopes), [open]);
}));

test('store ADR 0008: an output number is never given twice, even after the output with the highest is revoked', () => withStore(async ({ call, path }) => {
  await call('register_projection', { name: 'embeddings', kind: 'vector' });
  const { capture_id: a } = await call('append', screenText('a'));
  const { capture_id: b } = await call('append', screenText('b'));
  await call('add_projection_entry', { projection: 'embeddings', capture_id: a, entry_ref: 'v:0', output_kind: 'vector', output_json: '[1]' });
  await call('add_projection_entry', { projection: 'embeddings', capture_id: b, entry_ref: 'v:0', output_kind: 'vector', output_json: '[2]' });
  const [{ n: highest }] = query(path, 'SELECT MAX(output_sequence) AS n FROM projection_entry');
  await call('revoke', { scope_kind: 'capture', scope_value: b });

  await call('add_projection_entry', { projection: 'embeddings', capture_id: a, entry_ref: 'v:1', output_kind: 'vector', output_json: '[3]' });
  const [{ n: next }] = query(path, "SELECT output_sequence AS n FROM projection_entry WHERE entry_ref = 'v:1'");
  assert.ok(next > highest, `output number ${next} was not past ${highest}, given before`);

  // And no two outputs share a number.
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const [{ dupes }] = db.prepare('SELECT COUNT(*) - COUNT(DISTINCT output_sequence) AS dupes FROM projection_entry WHERE output_sequence IS NOT NULL').all();
    assert.equal(dupes, 0);
  } finally {
    db.close();
  }
}));
