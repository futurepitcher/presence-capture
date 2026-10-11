/**
 * The fake sensor: replays recorded observations (fixtures/*.jsonl) through
 * the daemon's write path in miniature (exclude, then redact, then append),
 * so a store can be filled anywhere, without a Mac or its permissions.
 */

import { isExcluded, parseExclusionList } from './exclusion.js';
import { redact } from './redact.js';

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
 * Replay a fixture into a store from openStore().
 *
 * @returns {{appended: number, excluded: number, redacted: number, captureIds: string[]}}
 */
export function replayFixture(store, { header, observations }) {
  const fragments = parseExclusionList(header.exclusion_list ?? '');
  const stats = { appended: 0, excluded: 0, redacted: 0, captureIds: [] };
  const append = (event) => {
    const id = store.appendCapture({ privacyLevel: 'standard', ...event });
    stats.appended += 1;
    stats.captureIds.push(id);
    return id;
  };
  const clean = (text) => {
    const out = redact(text);
    if (out !== text) stats.redacted += 1;
    return out;
  };

  for (const o of observations) {
    if (o.kind === 'audio') {
      const audioId = append({
        captureType: 'audio_segment',
        source: 'ambient_audio',
        sourceApp: o.device,
        capturedAt: o.at,
      });
      append({
        captureType: 'audio_transcript',
        source: 'ambient_audio',
        sourceApp: o.device,
        capturedAt: o.at,
        contentText: clean(o.transcript),
        extraction: 'asr',
        derivedFrom: audioId,
      });
      continue;
    }

    // Exclusion comes first: an excluded window is never read, so nothing of
    // it exists to redact or store (R8). Its time still passes, so activity
    // keeps the state alone (that the screen was locked, or in use) with no
    // trace of which app or window it was.
    if (isExcluded({ app: o.app, window: o.window }, { fragments, platform: header.platform })) {
      stats.excluded += 1;
      if (o.kind === 'activity') {
        append({
          captureType: 'activity',
          source: 'activity',
          capturedAt: o.at,
          contentText: JSON.stringify({ state: o.state, excluded: true }),
          extraction: 'none',
        });
      }
      continue;
    }

    if (o.kind === 'screen') {
      append({
        captureType: 'screen_text',
        source: 'screen',
        sourceApp: o.bundle ?? o.app,
        sourceUrl: o.url ?? null,
        capturedAt: o.at,
        contentText: clean(o.text),
        extraction: o.extraction ?? 'ocr',
      });
    } else if (o.kind === 'activity') {
      append({
        captureType: 'activity',
        source: 'activity',
        sourceApp: o.bundle ?? o.app,
        capturedAt: o.at,
        contentText: JSON.stringify({ app: o.app, window: clean(o.window ?? ''), state: o.state }),
        extraction: 'none',
      });
    } else {
      throw new Error(`unknown observation kind: ${o.kind}`);
    }
  }
  return stats;
}
