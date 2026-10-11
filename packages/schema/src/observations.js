/**
 * What a sensor may emit (ADR 0007): its header, then observations.
 * `cases/observations.json` holds every host to the same answers.
 */

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const str = (v) => typeof v === 'string';

/** Null when the header is valid; otherwise why not. */
export function headerError(h) {
  if (!h || typeof h !== 'object') return 'not an object';
  if (!str(h.sensor) || !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(h.sensor)) return 'sensor names are lower-case letters, digits and hyphens';
  if (h.protocol !== '1') return 'unknown protocol';
  return null;
}

/** Null when the observation is valid; otherwise why not. */
export function observationError(o) {
  if (!o || typeof o !== 'object' || Array.isArray(o)) return 'not an object';
  if (!str(o.at) || !ISO.test(o.at) || Number.isNaN(Date.parse(o.at))) return 'at must be an ISO 8601 UTC time';
  if (o.dedupe != null && (!str(o.dedupe) || o.dedupe.length === 0 || o.dedupe.length > 200)) return 'dedupe must be text of 1 to 200 characters';
  switch (o.kind) {
    case 'screen':
      if (!str(o.app) || !str(o.window) || !str(o.text)) return 'screen needs app, window and text';
      if (o.url != null && !str(o.url)) return 'url must be text';
      if (o.extraction != null && !['accessibility', 'ocr'].includes(o.extraction)) return 'unknown extraction';
      return null;
    case 'activity':
      if (!str(o.app) || (o.window != null && !str(o.window))) return 'activity needs app';
      if (!['active', 'idle', 'locked'].includes(o.state)) return 'unknown activity state';
      return null;
    case 'audio':
      if (!['input', 'output'].includes(o.device) || !str(o.transcript)) return 'audio needs device input or output, and transcript';
      if (o.seconds != null && typeof o.seconds !== 'number') return 'seconds must be a number';
      return null;
    default:
      return `unknown kind: ${o.kind}`;
  }
}
