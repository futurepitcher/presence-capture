/**
 * Vector-store interface.
 *
 * The spec defines the interface; LanceDB is the shipped default. An
 * implementation may substitute any backend, but revocation propagation (R3)
 * is mandatory regardless of backend — that is the one thing this interface
 * does not make optional.
 *
 * A backend becomes conformant by passing `conformance/vector-store.test.js`
 * against its own adapter.
 *
 * @typedef {object} VectorStore
 * @property {(e: {captureId: string, entryRef: string, vector: number[]}) => void} upsert
 * @property {(captureIds: string[]) => number} deleteByCaptureIds  returns entries removed
 * @property {(captureId: string) => string[]} entryRefsFor
 * @property {() => number} size
 */

/**
 * Reference in-memory implementation. Used by the conformance suite so the
 * interface is exercised without pulling in a backend dependency.
 *
 * @returns {VectorStore}
 */
export function createInMemoryVectorStore() {
  /** @type {Map<string, Map<string, number[]>>} */
  const byCapture = new Map();

  return {
    upsert({ captureId, entryRef, vector }) {
      if (!byCapture.has(captureId)) byCapture.set(captureId, new Map());
      byCapture.get(captureId).set(entryRef, vector);
    },
    deleteByCaptureIds(captureIds) {
      let removed = 0;
      for (const id of captureIds) {
        removed += byCapture.get(id)?.size ?? 0;
        byCapture.delete(id);
      }
      return removed;
    },
    entryRefsFor(captureId) {
      return [...(byCapture.get(captureId)?.keys() ?? [])];
    },
    size() {
      let n = 0;
      for (const entries of byCapture.values()) n += entries.size;
      return n;
    },
  };
}

/**
 * Bind a VectorStore to a store's revocation path so that revoking a capture
 * removes its vectors and records the per-projection receipt R3 requires.
 *
 * Any backend wired through this helper inherits R3 conformance.
 *
 * @param {object} store  a store from openStore()
 * @param {VectorStore} vectors
 * @param {string} projectionName
 */
export function bindVectorStore(store, vectors, projectionName = 'vectors') {
  store.registerProjection({ name: projectionName, kind: 'vector' });

  return {
    index({ captureId, entryRef, vector }) {
      vectors.upsert({ captureId, entryRef, vector });
      store.addProjectionEntry({ projection: projectionName, captureId, entryRef });
    },

    /** Revoke, then prune the backend using the ids the store reports. */
    revoke(scope) {
      const result = store.revoke(scope);
      const removed = vectors.deleteByCaptureIds(result.revokedCaptureIds);
      return { ...result, vectorEntriesRemoved: removed };
    },
  };
}
