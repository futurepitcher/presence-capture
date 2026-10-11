#!/usr/bin/env node
/**
 * The reference conformance driver: newline-delimited JSON requests on stdin,
 * one response per line on stdout (docs/spec/DRIVER.md). Opens no socket.
 */

import { createDriverHandler } from '../src/driver.js';
import { eachLine, jsonLine } from '../src/lines.js';

const handle = createDriverHandler();

eachLine(process.stdin, (line) => {
  if (line.trim() === '') return;
  let response;
  try {
    response = handle(JSON.parse(line));
  } catch {
    response = { id: null, ok: false, error: { code: 'bad_request', message: 'not JSON' } };
  }
  process.stdout.write(jsonLine(response));
});
