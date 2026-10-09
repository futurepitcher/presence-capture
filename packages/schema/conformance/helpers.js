import { openStore } from '../src/store.js';

export const FUTURE = '2099-01-01T00:00:00Z';

/** A store with an audio capture, its transcript, and both indexed. */
export function seedAudioChain() {
  const store = openStore();
  store.registerProjection({ name: 'text_index', kind: 'index' });
  store.registerProjection({ name: 'vectors', kind: 'vector' });

  const audioId = store.appendCapture({
    captureType: 'audio_segment',
    source: 'ambient_audio',
    privacyLevel: 'standard',
    classification: 'work',
    capturedAt: '2026-10-09T10:00:00Z',
  });

  const transcriptId = store.appendCapture({
    captureType: 'audio_transcript',
    source: 'ambient_audio',
    privacyLevel: 'standard',
    classification: 'work',
    contentText: 'we agreed to ship on friday',
    extraction: 'asr',
    derivedFrom: audioId,
    capturedAt: '2026-10-09T10:00:05Z',
  });

  store.addProjectionEntry({ projection: 'text_index', captureId: transcriptId, entryRef: 'fts:1' });
  store.addProjectionEntry({ projection: 'vectors', captureId: transcriptId, entryRef: 'vec:1' });
  store.addProjectionEntry({ projection: 'vectors', captureId: audioId, entryRef: 'vec:0' });

  return { store, audioId, transcriptId };
}

export function countEntries(store, projection) {
  return store.db
    .prepare('SELECT COUNT(*) AS n FROM projection_entry WHERE projection_name = ?')
    .get(projection).n;
}
