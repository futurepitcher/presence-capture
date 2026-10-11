/**
 * The gate every observation passes before it's written, whoever observed
 * it: validated (cases/observations.json), then excluded (R8), then redacted,
 * then appended, where the store seals it (R11). The built-in sensors, the
 * fake sensor and sensor plugins (ADR 0007) all go through it.
 */

import { isExcluded } from './exclusion.js';
import { observationError } from './observations.js';
import { redact } from './redact.js';

/**
 * @param {object} store  a store from openStore()
 * @param {{fragments?: string[], platform?: string, source?: string}} [options]
 *   `source` names every capture's source, as a sensor plugin's are
 *   (`sensor:<name>`); unset, each kind keeps its built-in source.
 */
export function createGate(store, { fragments = [], platform = 'macos', source } = {}) {
  const stats = { appended: 0, excluded: 0, redacted: 0, invalid: 0, captureIds: [] };
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

  function ingest(o) {
    if (observationError(o)) {
      stats.invalid += 1;
      return;
    }

    if (o.kind === 'audio') {
      const audioId = append({
        captureType: 'audio_segment', source: source ?? 'ambient_audio', sourceApp: o.device, capturedAt: o.at,
      });
      append({
        captureType: 'audio_transcript', source: source ?? 'ambient_audio', sourceApp: o.device, capturedAt: o.at,
        contentText: clean(o.transcript), extraction: 'asr', derivedFrom: audioId,
      });
      return;
    }

    // Exclusion comes first: an excluded window is never read, so nothing of
    // it exists to redact or store (R8). Its time still passes, so activity
    // keeps the state alone (that the screen was locked, or in use) with no
    // trace of which app or window it was.
    if (isExcluded({ app: o.app, window: o.window ?? '' }, { fragments, platform })) {
      stats.excluded += 1;
      if (o.kind === 'activity') {
        append({
          captureType: 'activity', source: source ?? 'activity', capturedAt: o.at,
          contentText: JSON.stringify({ state: o.state, excluded: true }), extraction: 'none',
        });
      }
      return;
    }

    if (o.kind === 'screen') {
      append({
        captureType: 'screen_text', source: source ?? 'screen', sourceApp: o.bundle ?? o.app,
        sourceUrl: o.url ?? null, capturedAt: o.at, contentText: clean(o.text), extraction: o.extraction ?? 'ocr',
      });
    } else {
      append({
        captureType: 'activity', source: source ?? 'activity', sourceApp: o.bundle ?? o.app, capturedAt: o.at,
        contentText: JSON.stringify({ app: o.app, window: clean(o.window ?? ''), state: o.state }), extraction: 'none',
      });
    }
  }

  return { ingest, stats };
}
