import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { isExcluded, parseExclusionList, SELF_WINDOWS, SYSTEM_APPS } from '../../src/exclusion.js';
import { cleanSourceUrl, redact } from '../../src/redact.js';

const cases = (name) => JSON.parse(readFileSync(new URL(`../../cases/${name}.json`, import.meta.url), 'utf8'));

const exclusion = cases('exclusion');
const redaction = cases('redaction');
const sourceUrl = cases('source-url');

test('R8: the reference holds the same built-in lists as the shared cases', () => {
  assert.deepEqual(SYSTEM_APPS, exclusion.system_apps);
  assert.deepEqual(SELF_WINDOWS, exclusion.self_windows);
});

for (const { text, fragments } of exclusion.parse) {
  test(`R8: the user's list parses: ${JSON.stringify(text).slice(0, 40)}`, () => {
    assert.deepEqual(parseExclusionList(text), fragments);
  });
}

for (const c of exclusion.cases) {
  test(`R8: ${c.excluded ? 'excluded' : 'captured'}: ${c.why}`, () => {
    assert.equal(isExcluded({ app: c.app, window: c.window }, { fragments: c.fragments, platform: c.platform }), c.excluded);
  });
}

test("R8: an adopter's own windows are excluded alongside the built-in ones", () => {
  const window = { app: 'Google Chrome', window: 'Presence Voice' };
  assert.equal(isExcluded(window), false);
  assert.equal(isExcluded(window, { selfWindows: ['presence voice'] }), true);
});

for (const c of redaction.cases) {
  test(`redaction: ${c.name}`, () => {
    const out = redact(c.input);
    if ('output' in c) assert.equal(out, c.output);
    for (const leak of c.must_not_contain ?? []) assert.ok(!out.includes(leak), `leaked ${leak}: ${out}`);
  });
}

for (const c of sourceUrl.cases) {
  test(`source URL: ${c.name}`, () => {
    assert.equal(cleanSourceUrl(c.input), c.output);
  });
}

test('source URL: cut to its longest', () => {
  const long = `https://example.com/${'a'.repeat(5000)}`;
  assert.equal([...cleanSourceUrl(long)].length, sourceUrl.max_length);
});

test('redaction runs in linear time over many private-key starts with no end', () => {
  // A page can show thousands of them, unseen; each capture of it is redacted.
  const text = '-----BEGIN PRIVATE KEY-----\n'.repeat(8000);
  const started = Date.now();
  assert.equal(redact(text), '[PRIVATE_KEY]');
  assert.ok(Date.now() - started < 1000, `took ${Date.now() - started} ms`);
});

test('redaction runs in linear time over a long run of letters or digits', () => {
  // Captured text can hold a long base64 or hex blob, and redaction runs in
  // the capture path.
  const started = Date.now();
  for (const run of ['x'.repeat(400_000), '7'.repeat(400_000), 'a1.'.repeat(130_000)]) assert.equal(redact(run), run);
  assert.ok(Date.now() - started < 2_000, `${Date.now() - started} ms`);
});
