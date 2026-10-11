/**
 * Pinning a sensor (ADR 0007): what runs is what was approved. A sensor's
 * pins are the SHA-256 of its executable and of every file its command names
 * (a script), keyed by absolute path. A directory it's given (a repository to
 * watch) is data, not code, and isn't pinned. A sensor whose pins are missing
 * or don't match what's on disk now isn't run until it's approved again.
 */

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { isAbsolute } from 'node:path';

/** The pins for a command as it is on disk now. */
export function computePins(command) {
  if (!Array.isArray(command) || command.length === 0 || !isAbsolute(command[0])) {
    throw new Error("a sensor's command starts with the absolute path of its executable");
  }
  const pins = {};
  for (const [i, arg] of command.entries()) {
    if (!isAbsolute(arg)) continue;
    let stat;
    try {
      stat = statSync(arg);
    } catch {
      if (i === 0) throw new Error(`no executable at ${arg}`);
      continue;
    }
    if (stat.isFile()) pins[arg] = createHash('sha256').update(readFileSync(arg)).digest('hex');
  }
  return pins;
}

/** Null when the command on disk is what was approved; otherwise what changed. */
export function pinError(command, approved) {
  if (!approved || Object.keys(approved).length === 0) return 'not approved';
  const now = computePins(command);
  const paths = new Set([...Object.keys(now), ...Object.keys(approved)]);
  for (const path of [...paths].sort()) {
    if (now[path] !== approved[path]) return `${path} has changed since it was approved`;
  }
  return null;
}
