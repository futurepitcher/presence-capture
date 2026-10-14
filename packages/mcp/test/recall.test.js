import assert from 'node:assert/strict';
import test from 'node:test';
import { openStore } from '@presence-capture/schema';
import { createRecall, openMemory } from '../src/recall.js';

const FUTURE = '2099-01-01T00:00:00.000Z';

test('recall: memory keeps its temporary storage in memory too', () => {
  const memory = openMemory();
  assert.equal(memory.prepare('PRAGMA temp_store').get().temp_store, 2);
  memory.close();
});

test('recall: a session answer reflects a revocation that lands between computing it and serving it', () => {
  const store = openStore();
  const at = (minutes) => new Date(Date.now() - minutes * 60_000).toISOString();
  const activity = (minutes, app, window) => store.appendCapture({
    captureType: 'activity', source: 'activity', privacyLevel: 'standard', extraction: 'none',
    contentText: JSON.stringify({ app, window, state: 'active' }), capturedAt: at(minutes),
  });
  const first = activity(20, 'Notes', 'Plan');
  activity(19.9, 'Slack', 'Dana');
  const back = activity(19.8, 'Notes', 'Plan');
  const grantId = store.issueGrant({ clientId: 'agent', expiresAt: FUTURE });

  // Another writer forgets the return to Notes just as the answer is served.
  let forgotten = false;
  const racing = Object.create(store);
  racing.createReader = (id) => {
    const reader = store.createReader(id);
    return {
      ...reader,
      readCaptures: (request) => {
        if (!forgotten) {
          forgotten = true;
          store.revoke({ scopeKind: 'capture', scopeValue: back });
        }
        return reader.readCaptures(request);
      },
    };
  };
  const recall = createRecall({ store: racing, grantId });
  const { session } = recall.call('now', {});
  assert.ok(!session.capture_ids.includes(back), 'the session still listed a capture revoked before it was served');
  assert.ok(forgotten);
  assert.notEqual(session.id, `ses_${back}`);
  // Without the return to Notes, the visit to Slack is its own session, and the latest.
  assert.ok(!session.capture_ids.includes(first));
  recall.close();
  store.close();
});
