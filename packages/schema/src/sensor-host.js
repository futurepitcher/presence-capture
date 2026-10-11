/**
 * Hosts a sensor plugin (ADR 0007): runs its command, reads its header and
 * observations from stdout, and puts each through the gate (src/gate.js).
 * The plugin never touches the store and never sees the master key.
 */

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createGate } from './gate.js';
import { headerError } from './observations.js';

/**
 * @param {{command: string[], store: object, fragments?: string[], platform?: string,
 *   held?: () => boolean, timeoutMs?: number}} options
 *   `held` drops observations while capture is held (paused, locked); they are
 *   never queued. `timeoutMs` stops a sensor that runs on.
 * @returns {Promise<{name: string, stats: object, dropped: number}>}
 */
export function runSensor({ command, store, fragments = [], platform = 'macos', held = () => false, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), { stdio: ['ignore', 'pipe', 'ignore'] });
    const timer = timeoutMs ? setTimeout(() => child.kill(), timeoutMs) : null;
    let name = null;
    let gate = null;
    let dropped = 0;
    let failed = null;

    createInterface({ input: child.stdout }).on('line', (line) => {
      if (line.trim() === '' || failed) return;
      let value;
      try {
        value = JSON.parse(line);
      } catch {
        value = undefined;
      }
      if (!gate) {
        const error = headerError(value);
        if (error) {
          failed = new Error(`sensor header: ${error}`);
          child.kill();
          return;
        }
        name = value.sensor;
        gate = createGate(store, { fragments, platform, source: `sensor:${name}` });
        return;
      }
      if (held()) {
        dropped += 1;
        return;
      }
      gate.ingest(value);
    });

    child.on('error', (err) => {
      failed ??= err;
    });
    child.on('close', () => {
      if (timer) clearTimeout(timer);
      if (failed) reject(failed);
      else if (!gate) reject(new Error('sensor exited without a header'));
      else resolve({ name, stats: gate.stats, dropped });
    });
  });
}
