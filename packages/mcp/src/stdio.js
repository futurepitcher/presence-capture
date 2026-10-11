#!/usr/bin/env node
/**
 * stdio transport. Local only: this process speaks newline-delimited JSON-RPC
 * on stdin/stdout and opens no socket of any kind.
 *
 * Usage:
 *   presence-capture-mcp --store <path> --grant <grant_id> --master-key-file <path>
 *
 * The master key file holds the store's 32-byte key, raw or as 64 hex
 * characters. The store never writes it down; whoever runs this supplies it.
 */

import { readFileSync } from 'node:fs';
import { eachLine, jsonLine, openStore } from '@presence-capture/schema';
import { createMcpServer } from './server.js';

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
}

const storePath = arg('store');
const grantId = arg('grant');
const keyFile = arg('master-key-file');

if (!storePath || !grantId || !keyFile) {
  process.stderr.write(
    'usage: presence-capture-mcp --store <path> --grant <grant_id> --master-key-file <path>\n',
  );
  process.exit(2);
}

const keyBytes = readFileSync(keyFile);
const keyText = keyBytes.toString('utf8').trim();
const masterKey = /^[0-9a-f]{64}$/i.test(keyText) ? Buffer.from(keyText, 'hex') : keyBytes;

const server = createMcpServer({ store: openStore(storePath, { masterKey }), grantId });

// One request a line, split on "\n" alone: captured text holds U+2028, which
// readline would also split on, cutting a request in two.
eachLine(process.stdin, (line) => {
  if (line.trim() === '') return;
  let response;
  try {
    response = server.handle(JSON.parse(line));
  } catch {
    response = { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } };
  }
  if (response !== null) process.stdout.write(jsonLine(response));
});
