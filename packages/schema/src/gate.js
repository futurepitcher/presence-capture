/**
 * The gate every observation passes before it's written, whoever observed
 * it: validated (cases/observations.json), then excluded (R8), then redacted,
 * then appended, where the store seals it (R11). The built-in sensors, the
 * fake sensor and sensor plugins (ADR 0007) all go through it.
 */

import { randomUUID } from 'node:crypto';
import { isExcluded } from './exclusion.js';
import { observationError } from './observations.js';
import { redact } from './redact.js';
import { RevokedError } from './store.js';

/**
 * @param {object} store  a store from openStore()
 * @param {{fragments?: string[], platform?: string, source?: string}} [options]
 *   `source` names every capture's source, as a sensor plugin's are
 *   (`sensor:<name>`); unset, each kind keeps its built-in source.
 */
// How far ahead of now an observation may be stamped (clocks differ a little): further, and it's
// refused, since nothing (Forget, retention) can reach what's stamped in the future.
export const FUTURE_SKEW_MS = 300_000;
// The longest an app, bundle or device name is kept, with no control characters: plain metadata.
export const NAME_LENGTH = 256;
const name = (value) => (value == null ? value : [...String(value).replace(/[\u0000-\u001f\u007f]/g, '')].slice(0, NAME_LENGTH).join(''));

export function createGate(store, { fragments = [], platform = 'macos', source } = {}) {
  const stats = { appended: 0, excluded: 0, redacted: 0, invalid: 0, duplicates: 0, refused: 0, captureIds: [] };
  // One observation's captures, all in one transaction (an audio segment and
  // its transcript land together, or neither does). An observation a sensor
  // marked with `dedupe` lands once per source: a sensor restarted, or
  // replaying what it already sent, adds nothing, and what was revoked
  // doesn't come back. One stamped inside a revoked time range is refused, as
  // the store refuses it. The first capture's id, or null when nothing landed.
  const append = (events, o) => {
    const [head, ...rest] = events.map((e) => ({ privacyLevel: 'standard', ...e }));
    const marked = o.dedupe == null ? head : { ...head, dedupeKey: store.dedupeKeyFor(head.source, o.dedupe) };
    try {
      const ids = store.appendAll([marked, ...rest]);
      stats.appended += ids.length;
      stats.captureIds.push(...ids);
      return ids[0];
    } catch (err) {
      if (err instanceof RevokedError) {
        stats.refused += 1;
        return null;
      }
      // Only a dedupe key already kept: any other refusal is a failure, and is raised.
      if (o.dedupe == null || !/UNIQUE.*capture_event\.dedupe_key/.test(err.message)) throw err;
      stats.duplicates += 1;
      return null;
    }
  };
  const clean = (text) => {
    const out = redact(text);
    if (out !== text) stats.redacted += 1;
    return out;
  };

  function ingest(observation) {
    if (observationError(observation) || Date.parse(observation.at) > Date.now() + FUTURE_SKEW_MS) {
      stats.invalid += 1;
      return;
    }
    const o = { ...observation, app: name(observation.app), bundle: name(observation.bundle), device: name(observation.device) };

    if (o.kind === 'audio') {
      const audioId = `cap_${randomUUID()}`;
      append([{
        captureId: audioId, captureType: 'audio_segment', source: source ?? 'ambient_audio', sourceApp: o.device, capturedAt: o.at,
      }, {
        captureType: 'audio_transcript', source: source ?? 'ambient_audio', sourceApp: o.device, capturedAt: o.at,
        contentText: clean(o.transcript), extraction: 'asr', derivedFrom: audioId,
      }], o);
      return;
    }

    // Exclusion comes first: an excluded window is never read, so nothing of
    // it exists to redact or store (R8). Its time still passes, so activity
    // keeps the state alone (that the screen was locked, or in use) with no
    // trace of which app or window it was.
    if (isExcluded({ app: o.app, window: o.window ?? '' }, { fragments, platform })) {
      stats.excluded += 1;
      if (o.kind === 'activity') {
        append([{
          captureType: 'activity', source: source ?? 'activity', capturedAt: o.at,
          contentText: JSON.stringify({ state: o.state, excluded: true }), extraction: 'none',
        }], o);
      }
      return;
    }

    if (o.kind === 'screen') {
      append([{
        captureType: 'screen_text', source: source ?? 'screen', sourceApp: o.bundle ?? o.app,
        sourceUrl: o.url ?? null, capturedAt: o.at, contentText: clean(o.text), extraction: o.extraction ?? 'ocr',
      }], o);
    } else {
      append([{
        captureType: 'activity', source: source ?? 'activity', sourceApp: o.bundle ?? o.app, capturedAt: o.at,
        contentText: JSON.stringify({ app: o.app, window: clean(o.window ?? ''), state: o.state }), extraction: 'none',
      }], o);
    }
  }

  return { ingest, stats };
}
