/**
 * The conformance driver protocol (docs/spec/DRIVER.md), over the reference
 * store. An implementation in another language exposes the same protocol from
 * its own executable, and the store-layer suite drives it the same way.
 */

import { openStore } from './store.js';

export const DRIVER_PROTOCOL_VERSION = '1';

class DriverError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/** What a failure means to the suite, not how this implementation phrased it. */
function codeFor(err) {
  if (err instanceof DriverError) return err.code;
  if (/does not open this store|needs its masterKey|masterKey must be/.test(err.message)) return 'key';
  if (/constraint|append-only|write-once/i.test(err.message)) return 'constraint';
  return 'internal';
}

/**
 * @param {{open?: typeof openStore}} [options]  `open` lets the mutation suite
 *   drive a deliberately broken store through the same protocol.
 * @returns {(request: {id?: unknown, op: string, args?: object}) => object}
 */
export function createDriverHandler({ open = openStore } = {}) {
  let store = null;

  const need = () => {
    if (!store) throw new DriverError('bad_request', 'no store is open');
    return store;
  };

  const ops = {
    hello: () => ({
      protocol: DRIVER_PROTOCOL_VERSION,
      implementation: 'presence-capture reference (JavaScript)',
    }),

    open: ({ path, master_key_hex: keyHex }) => {
      if (store) throw new DriverError('bad_request', 'a store is already open');
      if (!/^[0-9a-f]{64}$/i.test(keyHex ?? '')) {
        throw new DriverError('bad_request', 'master_key_hex must be 64 hex characters');
      }
      store = open(path, { masterKey: Buffer.from(keyHex, 'hex') });
      return {};
    },

    append: (a) => ({
      capture_id: need().appendCapture({
        captureId: a.capture_id,
        capturedAt: a.captured_at,
        captureType: a.capture_type,
        source: a.source,
        sourceApp: a.source_app,
        sourceUrl: a.source_url,
        privacyLevel: a.privacy_level,
        classification: a.classification,
        contentText: a.content_text,
        payload: a.payload && {
          bytes: Buffer.from(a.payload.bytes_base64, 'base64'),
          mediaType: a.payload.media_type,
        },
        extraction: a.extraction,
        derivedFrom: a.derived_from,
        dedupeKey: a.dedupe_key,
      }),
    }),

    register_projection: ({ name, kind }) => {
      need().registerProjection({ name, kind });
      return {};
    },

    add_projection_entry: ({ projection, capture_id: captureId, entry_ref: entryRef }) => {
      need().addProjectionEntry({ projection, captureId, entryRef });
      return {};
    },

    revoke: ({ scope_kind: scopeKind, scope_value: scopeValue, reason }) => {
      const { revocationId, revokedCaptureIds } = need().revoke({ scopeKind, scopeValue, reason });
      return { revocation_id: revocationId, revoked_capture_ids: revokedCaptureIds };
    },

    retain: ({ days, now }) => {
      const result = need().retain({ days, now: now ? new Date(now) : undefined });
      return result
        ? { revocation_id: result.revocationId, revoked_capture_ids: result.revokedCaptureIds }
        : { revocation_id: null, revoked_capture_ids: [] };
    },

    content: ({ capture_id: captureId }) => ({ text: need().contentText(captureId) }),

    payload: ({ capture_id: captureId }) => {
      const bytes = need().payloadBytes(captureId);
      return { bytes_base64: bytes ? bytes.toString('base64') : null };
    },

    close: () => {
      store?.close();
      store = null;
      return {};
    },
  };

  return function handle(request) {
    const id = request?.id ?? null;
    const op = ops[request?.op];
    if (!op) return { id, ok: false, error: { code: 'bad_request', message: `unknown op: ${request?.op}` } };
    try {
      return { id, ok: true, result: op(request.args ?? {}) };
    } catch (err) {
      return { id, ok: false, error: { code: codeFor(err), message: err.message } };
    }
  };
}
