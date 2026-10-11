/**
 * How the store-layer suite reaches an implementation: through the driver
 * protocol (docs/spec/DRIVER.md), never through its API.
 *
 * Set PRESENCE_CAPTURE_DRIVER to the command that starts your driver, e.g.
 *   PRESENCE_CAPTURE_DRIVER="/usr/local/bin/pcap-driver" npm run conformance:store
 * Unset, the suite drives the reference implementation's own driver process.
 */

import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { eachLine, jsonLine } from '../src/lines.js';

const REFERENCE_DRIVER = join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'driver.js');

export class DriverError extends Error {
  constructor({ code, message }) {
    super(`${code}: ${message}`);
    this.code = code;
  }
}

/** The command the suite runs: the environment's, or the reference driver. */
export function driverCommand() {
  const configured = process.env.PRESENCE_CAPTURE_DRIVER?.trim();
  return configured ? configured.split(/\s+/) : [process.execPath, REFERENCE_DRIVER];
}

/** Start a driver process. Requests are answered in order, one line each. */
export function startDriver(command = driverCommand()) {
  const child = spawn(command[0], command.slice(1), { stdio: ['pipe', 'pipe', 'inherit'] });
  const pending = new Map();
  let nextId = 1;

  eachLine(child.stdout, (line) => {
    if (line.trim() === '') return;
    const response = JSON.parse(line);
    const waiter = pending.get(response.id);
    if (!waiter) return;
    pending.delete(response.id);
    if (response.ok) waiter.resolve(response.result);
    else waiter.reject(new DriverError(response.error));
  });
  child.on('exit', (code) => {
    for (const waiter of pending.values()) waiter.reject(new Error(`driver exited with ${code}`));
    pending.clear();
  });

  return {
    call(op, args = {}) {
      const id = nextId++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        child.stdin.write(jsonLine({ id, op, args }));
      });
    },
    async close() {
      if (child.exitCode === null) await this.call('close').catch(() => {});
      child.stdin.end();
      if (child.exitCode === null) await new Promise((resolve) => child.once('exit', resolve));
    },
  };
}

/** The same client shape over an in-process handler, for mutants of the reference store. */
export function inProcessDriver(handle) {
  let nextId = 1;
  return {
    async call(op, args = {}) {
      const response = handle({ id: nextId++, op, args });
      if (!response.ok) throw new DriverError(response.error);
      return response.result;
    },
    async close() {
      handle({ op: 'close' });
    },
  };
}
