/**
 * The projector kit (ADR 0007): loads a projector as the host would, runs it
 * over a synthetic day through a grant made from its manifest, then revokes
 * what it projected. Returns the failures, rather than asserting, so a
 * projector's author can see all of them at once.
 */

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { parseFixture, replayFixture } from '../../src/fake-sensor.js';
import { grantFor, loadProjector, runProjector } from '../../src/projector-host.js';
import { openStore } from '../../src/store.js';

const DAY = new URL('../../fixtures/a-short-day.jsonl', import.meta.url);

/** @returns {Promise<string[]>} */
export async function checkProjector({ bytes, manifest, timeoutMs }) {
  const failures = [];
  let projector;
  try {
    projector = loadProjector({ bytes, manifest, approvedSha256: createHash('sha256').update(bytes).digest('hex') });
  } catch (err) {
    return [err.message];
  }

  const store = openStore();
  try {
    replayFixture(store, parseFixture(readFileSync(DAY, 'utf8')));
    const grantId = grantFor(store, manifest, { expiresAt: '2099-01-01T00:00:00Z' });
    const first = await runProjector({ store, projector, grantId, timeoutMs });
    if (first.read === 0) failures.push('read nothing: its manifest reads no capture type in the synthetic day');
    if (first.timedOut) failures.push(`${first.timedOut} capture(s) ran over the time limit`);
    if (first.failed) failures.push(`${first.failed} capture(s) failed (a trap, or output outside its memory or over the limit)`);
    if (first.rejected) failures.push(`${first.rejected} output(s) rejected: not {"entries": [...]} of the kinds its manifest writes`);

    const again = await runProjector({ store, projector, grantId, timeoutMs });
    if (again.read !== 0) failures.push('read captures again after its watermark');

    // Only what its manifest reads ever reached it.
    const served = store.db.prepare(`
      SELECT DISTINCT e.capture_type FROM egress_record r, json_each(r.capture_ids) j
      JOIN capture_event e ON e.capture_id = j.value WHERE r.client_id = ?
    `).all(`projector:${manifest.projector}`).map((r) => r.capture_type);
    const outside = served.filter((t) => !manifest.reads.capture_types.includes(t));
    if (outside.length) failures.push(`was served capture types outside its manifest: ${outside.join(', ')}`);

    // Revoking what it projected from erases what it projected (R3, R11).
    const projected = store.db.prepare('SELECT DISTINCT capture_id FROM projection_entry WHERE projection_name = ?')
      .all(manifest.projection.name).map((r) => r.capture_id);
    for (const captureId of projected) {
      const { revocationId } = store.revoke({ scopeKind: 'capture', scopeValue: captureId, reason: 'kit' });
      if (store.projectionOutputs({ projection: manifest.projection.name, captureId }).length > 0) failures.push('an output survived its capture\'s revocation');
      const receipt = store.db.prepare('SELECT 1 FROM projection_revocation WHERE projection_name = ? AND revocation_id = ?')
        .get(manifest.projection.name, revocationId);
      if (!receipt) failures.push('no projection receipt for a revocation');
    }
    if (store.db.prepare('SELECT COUNT(*) AS n FROM projection_entry WHERE projection_name = ?').get(manifest.projection.name).n > 0) {
      failures.push('projection entries survived revocation');
    }
  } catch (err) {
    failures.push(`kit could not run: ${err.message}`);
  } finally {
    store.close();
  }
  return failures;
}
