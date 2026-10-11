/**
 * The fake sensor: replays recorded observations (fixtures/*.jsonl) through
 * the gate every sensor's observations pass (src/gate.js), so a store can be
 * filled anywhere, without a Mac or its permissions.
 */

import { parseExclusionList } from './exclusion.js';
import { createGate } from './gate.js';

/** Parse a fixture: its header line, then one observation a line. */
export function parseFixture(text) {
  const [header, ...observations] = text
    .split('\n')
    .filter((line) => line.trim() !== '')
    .map((line) => JSON.parse(line));
  if (header?.version !== 1) throw new Error(`unsupported fixture version: ${header?.version}`);
  return { header, observations };
}

/**
 * Replay a fixture into a store from openStore(), as the built-in sensors
 * would have captured it.
 *
 * @returns {{appended: number, excluded: number, redacted: number, invalid: number, captureIds: string[]}}
 */
export function replayFixture(store, { header, observations }) {
  const gate = createGate(store, { fragments: parseExclusionList(header.exclusion_list ?? ''), platform: header.platform });
  for (const observation of observations) gate.ingest(observation);
  return gate.stats;
}
