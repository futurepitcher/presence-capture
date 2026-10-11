#!/usr/bin/env node
/**
 * Check a sensor plugin against the kit (ADR 0007).
 *
 * Usage:
 *   sensor-kit -- <command> [args...]
 */

import { checkSensor } from '../conformance/plugins/sensor-kit.js';

const at = process.argv.indexOf('--');
const command = at === -1 ? [] : process.argv.slice(at + 1);
if (command.length === 0) {
  process.stderr.write('usage: sensor-kit -- <command> [args...]\n');
  process.exit(2);
}

const failures = await checkSensor(command);
if (failures.length === 0) {
  process.stdout.write('PASS\n');
} else {
  process.stdout.write(`FAIL\n${failures.map((f) => `  - ${f}`).join('\n')}\n`);
  process.exit(1);
}
