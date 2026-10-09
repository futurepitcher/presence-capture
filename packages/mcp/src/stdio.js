#!/usr/bin/env node
/**
 * stdio transport. Local only: this process speaks newline-delimited JSON-RPC
 * on stdin/stdout and opens no socket of any kind.
 *
 * Usage:
 *   presence-capture-mcp --store <path> --grant <grant_id>
 */

import { createInterface } from 'node:readline';
import { openStore } from '@presence-capture/schema';
import { createMcpServer } from './server.js';

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
}

const storePath = arg('store');
const grantId = arg('grant');

if (!storePath || !grantId) {
  process.stderr.write('usage: presence-capture-mcp --store <path> --grant <grant_id>\n');
  process.exit(2);
}

const server = createMcpServer({ store: openStore(storePath), grantId });

createInterface({ input: process.stdin }).on('line', (line) => {
  if (line.trim() === '') return;
  let response;
  try {
    response = server.handle(JSON.parse(line));
  } catch {
    response = { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } };
  }
  if (response !== null) process.stdout.write(`${JSON.stringify(response)}\n`);
});
