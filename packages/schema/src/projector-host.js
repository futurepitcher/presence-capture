/**
 * Hosts projector plugins (ADR 0007). A projector computes; the store keeps
 * what it computed.
 *
 * - It's a WebAssembly module with no imports: no network, no files, no
 *   clock. It can't keep a copy anywhere or send one anywhere.
 * - It's the module that was approved: its SHA-256 must match, and its
 *   manifest bounds what it reads and writes.
 * - It reads through a grant made from its manifest, so every capture it sees
 *   is enveloped and egress-logged, and nothing outside its scope reaches it.
 * - Every capture gets a fresh instance under a time limit, and its output is
 *   validated before anything is written.
 * - What it returns is stored sealed under the source capture's key, so
 *   revoking the capture erases it with receipts (R3, R11).
 */

import { createHash } from 'node:crypto';
import { Worker } from 'node:worker_threads';
import { inspectWasm } from './wasm-check.js';

export const LIMITS = {
  /** 64 KiB pages: 16 MiB. */
  maxPages: 256,
  maxOutputBytes: 64 * 1024,
  maxEntries: 32,
  maxValueBytes: 16 * 1024,
  maxVectorLength: 4096,
  timeoutMs: 1000,
};

const NAME = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const REF = /^[A-Za-z0-9:._-]{1,128}$/;
const KINDS = ['text', 'vector', 'summary'];
const PROJECTION_KINDS = ['index', 'vector', 'summary'];
const GRANTABLE = ['standard', 'sensitive', 'excluded'];
const CAPTURE_TYPES = ['screen_frame', 'screen_text', 'audio_segment', 'audio_transcript', 'audio_alignment', 'activity'];

/** Null when the manifest is valid; otherwise why not. */
export function manifestError(m) {
  if (!m || typeof m !== 'object') return 'not an object';
  if (!NAME.test(m.projector ?? '')) return 'projector names are lower-case letters, digits and hyphens';
  if (m.protocol !== '1') return 'unknown protocol';
  if (!NAME.test(m.projection?.name ?? '') || !PROJECTION_KINDS.includes(m.projection?.kind)) return 'projection needs a name and a kind';
  const reads = m.reads ?? {};
  if (!Array.isArray(reads.capture_types) || reads.capture_types.length === 0
    || reads.capture_types.some((t) => !CAPTURE_TYPES.includes(t))) return 'reads.capture_types must name capture types';
  if (!Array.isArray(reads.privacy_levels) || reads.privacy_levels.length === 0
    || reads.privacy_levels.some((l) => !GRANTABLE.includes(l))) return 'reads.privacy_levels must name grantable levels';
  if (!Array.isArray(m.writes?.kinds) || m.writes.kinds.length === 0 || m.writes.kinds.some((k) => !KINDS.includes(k))) {
    return 'writes.kinds must name output kinds';
  }
  return null;
}

/**
 * Check a module and its manifest, and refuse anything that isn't the module
 * that was approved, or that could reach outside itself.
 *
 * @param {{bytes: Uint8Array, manifest: object, approvedSha256: string}} options
 */
export function loadProjector({ bytes, manifest, approvedSha256 }) {
  const error = manifestError(manifest);
  if (error) throw new Error(`manifest: ${error}`);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  if (sha256 !== approvedSha256) throw new Error('not the approved module: its SHA-256 has changed');

  const declared = inspectWasm(bytes);
  if (declared.imports > 0) throw new Error(`a projector may import nothing; this one imports ${declared.imports}`);
  const module = new WebAssembly.Module(bytes);
  if (WebAssembly.Module.imports(module).length > 0) throw new Error('a projector may import nothing');
  if (declared.memories.length !== 1) throw new Error('a projector declares exactly one memory');
  const [memory] = declared.memories;
  if (memory.memory64 || memory.max === null || memory.max > LIMITS.maxPages) {
    throw new Error(`a projector's memory must declare a maximum of at most ${LIMITS.maxPages} pages`);
  }
  const exports = Object.fromEntries(WebAssembly.Module.exports(module).map((e) => [e.name, e.kind]));
  if (exports.memory !== 'memory' || exports.alloc !== 'function' || exports.project !== 'function') {
    throw new Error('a projector exports memory, alloc and project');
  }
  return { bytes, manifest, sha256 };
}

/** The grant a projector reads through: exactly what its manifest says it reads. */
export function grantFor(store, manifest, { expiresAt }) {
  return store.issueGrant({
    clientId: `projector:${manifest.projector}`,
    expiresAt,
    privacyLevels: manifest.reads.privacy_levels,
    captureTypes: manifest.reads.capture_types,
    maxRowsPerQuery: 100,
  });
}

/** Null when an output is valid for this manifest; otherwise why not. */
function outputError(output, manifest) {
  if (!output || typeof output !== 'object' || !Array.isArray(output.entries)) return 'output must be {"entries": [...]}';
  if (output.entries.length > LIMITS.maxEntries) return `more than ${LIMITS.maxEntries} entries`;
  const refs = new Set();
  for (const entry of output.entries) {
    if (!REF.test(entry?.ref ?? '') || refs.has(entry.ref)) return 'each entry needs a unique ref';
    refs.add(entry.ref);
    if (!manifest.writes.kinds.includes(entry.kind)) return `kind ${entry.kind} is not one the manifest writes`;
    if (entry.value === undefined || Buffer.byteLength(JSON.stringify(entry.value)) > LIMITS.maxValueBytes) {
      return `each value is JSON of at most ${LIMITS.maxValueBytes} bytes`;
    }
    if (entry.kind === 'vector' && (!Array.isArray(entry.value) || entry.value.length > LIMITS.maxVectorLength
      || entry.value.some((x) => typeof x !== 'number' || !Number.isFinite(x)))) return 'a vector is an array of finite numbers';
  }
  return null;
}

/** One worker for a projector, restarted when a capture runs over its time. */
function workerFor(projector) {
  let worker = null;
  let nextId = 1;
  const start = () => {
    worker = new Worker(new URL('./projector-worker.js', import.meta.url), {
      workerData: { moduleBytes: projector.bytes, maxOutput: LIMITS.maxOutputBytes },
    });
  };
  start();
  return {
    run(input, timeoutMs) {
      const id = nextId++;
      return new Promise((resolve) => {
        const timer = setTimeout(() => {
          worker.removeListener('message', listen);
          worker.terminate();
          start();
          resolve({ ok: false, timedOut: true, error: 'over its time' });
        }, timeoutMs);
        const listen = (message) => {
          if (message.id !== id) return;
          clearTimeout(timer);
          worker.removeListener('message', listen);
          resolve(message);
        };
        worker.on('message', listen);
        worker.postMessage({ id, input });
      });
    },
    close: () => worker.terminate(),
  };
}

/**
 * Project what's new since the projector's watermark: read through its grant,
 * run each capture in a fresh instance, validate the output, and store it
 * sealed under the capture's key.
 *
 * @returns {Promise<{read: number, projected: number, entries: number, timedOut: number, failed: number, rejected: number}>}
 */
export async function runProjector({ store, projector, grantId, timeoutMs = LIMITS.timeoutMs, limit = 100 }) {
  const { manifest } = projector;
  const consumer = `projector:${manifest.projector}`;
  store.registerProjection({ name: manifest.projection.name, kind: manifest.projection.kind });
  const reader = store.createReader(grantId);
  const stats = { read: 0, projected: 0, entries: 0, timedOut: 0, failed: 0, rejected: 0 };
  const envelopes = reader.read({ tool: consumer, afterSequence: store.watermark(consumer), limit });
  const worker = workerFor(projector);
  try {
    for (const envelope of envelopes) {
      stats.read += 1;
      const { provenance } = envelope.presence_capture_untrusted;
      const result = await worker.run(Buffer.from(JSON.stringify(envelope)), timeoutMs);
      if (!result.ok) {
        if (result.timedOut) stats.timedOut += 1;
        else stats.failed += 1;
      } else {
        let output;
        try {
          output = JSON.parse(Buffer.from(result.output).toString('utf8'));
        } catch {
          output = undefined;
        }
        if (outputError(output, manifest)) {
          stats.rejected += 1;
        } else {
          try {
            for (const entry of output.entries) {
              store.addProjectionEntry({
                projection: manifest.projection.name, captureId: provenance.capture_id, entryRef: entry.ref,
                output: { kind: entry.kind, value: entry.value },
              });
            }
            stats.projected += 1;
            stats.entries += output.entries.length;
          } catch {
            // Revoked while it was being projected: nothing is kept for it.
            stats.failed += 1;
          }
        }
      }
      store.setWatermark(consumer, provenance.sequence);
    }
  } finally {
    await worker.close();
  }
  return stats;
}
