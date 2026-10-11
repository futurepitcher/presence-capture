/**
 * The sensor kit (ADR 0007): runs a sensor plugin into a fresh store, through
 * the gate, and fails it when it can't be trusted to extend capture. Returns
 * a list of failures rather than asserting, so a sensor's author can see all
 * of them at once.
 */

import { openStore } from '../../src/store.js';
import { runSensor } from '../../src/sensor-host.js';

/**
 * @param {string[]} command  the sensor's command line
 * @param {{timeoutMs?: number}} [options]  how long to let a sensor that runs on emit
 * @returns {Promise<string[]>}
 */
export async function checkSensor(command, { timeoutMs = 10_000 } = {}) {
  const store = openStore();
  const failures = [];
  try {
    const { name, stats } = await runSensor({ command, store, timeoutMs });
    if (stats.invalid > 0) failures.push(`${stats.invalid} observation(s) failed cases/observations.json's rules`);
    if (stats.appended + stats.excluded === 0) failures.push('emitted no observations');
    const sources = store.db.prepare('SELECT DISTINCT source FROM capture_event').all().map((r) => r.source);
    if (sources.some((s) => s !== `sensor:${name}`)) {
      failures.push(`captures landed as ${sources.join(', ')}, not sensor:${name}`);
    }
  } catch (err) {
    failures.push(err.message);
  } finally {
    store.close();
  }
  return failures;
}
