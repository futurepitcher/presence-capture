#!/usr/bin/env node
/**
 * The reference conformance driver: newline-delimited JSON requests on stdin,
 * one response per line on stdout (docs/spec/DRIVER.md). Opens no socket.
 */

import { createInterface } from 'node:readline';
import { createDriverHandler } from '../src/driver.js';

const handle = createDriverHandler();

createInterface({ input: process.stdin }).on('line', (line) => {
  if (line.trim() === '') return;
  let response;
  try {
    response = handle(JSON.parse(line));
  } catch {
    response = { id: null, ok: false, error: { code: 'bad_request', message: 'not JSON' } };
  }
  process.stdout.write(`${JSON.stringify(response)}\n`);
});
