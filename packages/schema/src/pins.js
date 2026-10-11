/**
 * Pinning a sensor (ADR 0007): what runs is what was approved. A sensor's
 * pins are the SHA-256 of its executable and of every regular file its
 * command names, keyed by absolute path:
 * - an argument that is a path, absolute or relative;
 * - the path in a `--flag=path` argument.
 *
 * Relative paths are resolved against SENSOR_CWD, the working directory every
 * sensor is started in, so a path means the same file when it's pinned as
 * when it runs. Symbolic links are followed: what's hashed is what runs. A
 * directory a sensor watches, or a device, isn't code and isn't pinned. A
 * sensor whose pins are missing or don't match what's on disk now isn't run
 * until it's approved again.
 */

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';

/** Every sensor runs here, so a relative path in its command names one file, always. */
export const SENSOR_CWD = '/';

/** The paths an argument could name: itself, and what follows `=` in a `--flag=path`. */
const candidates = (arg) => (arg.includes('=') ? [arg, arg.slice(arg.indexOf('=') + 1)] : [arg]);

/** The pins for a command as it is on disk now. */
export function computePins(command, { cwd = SENSOR_CWD } = {}) {
  if (!Array.isArray(command) || command.length === 0 || !isAbsolute(command[0])) {
    throw new Error("a sensor's command starts with the absolute path of its executable");
  }
  const pins = {};
  for (const [i, arg] of command.entries()) {
    for (const candidate of i === 0 ? [arg] : candidates(arg)) {
      if (candidate === '') continue;
      const path = resolve(cwd, candidate);
      let stat;
      try {
        stat = statSync(path);
      } catch {
        if (i === 0) throw new Error(`no executable at ${arg}`);
        continue;
      }
      if (stat.isFile()) pins[path] = createHash('sha256').update(readFileSync(path)).digest('hex');
    }
  }
  return pins;
}

/** Null when the command on disk is what was approved; otherwise what changed. */
export function pinError(command, approved, options) {
  if (!approved || Object.keys(approved).length === 0) return 'not approved';
  const now = computePins(command, options);
  const paths = new Set([...Object.keys(now), ...Object.keys(approved)]);
  for (const path of [...paths].sort()) {
    if (now[path] !== approved[path]) return `${path} has changed since it was approved`;
  }
  return null;
}
