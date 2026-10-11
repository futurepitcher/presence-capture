#!/usr/bin/env node
/**
 * Check a projector plugin against the kit (ADR 0007).
 *
 * Usage:
 *   projector-kit <module.wasm> <manifest.json>
 */

import { readFileSync } from 'node:fs';
import { checkProjector } from '../conformance/plugins/projector-kit.js';

const [wasm, manifestPath] = process.argv.slice(2);
if (!wasm || !manifestPath) {
  process.stderr.write('usage: projector-kit <module.wasm> <manifest.json>\n');
  process.exit(2);
}

const failures = await checkProjector({ bytes: new Uint8Array(readFileSync(wasm)), manifest: JSON.parse(readFileSync(manifestPath, 'utf8')) });
if (failures.length === 0) {
  process.stdout.write('PASS\n');
} else {
  process.stdout.write(`FAIL\n${failures.map((f) => `  - ${f}`).join('\n')}\n`);
  process.exit(1);
}
