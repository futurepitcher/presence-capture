/**
 * Runs a projector module (ADR 0007) off the host's thread, so a module that
 * never returns can be stopped. Every capture gets a fresh instance: nothing
 * one capture leaves in memory reaches another's output, or outlives its
 * revocation. Instantiated with no imports at all.
 */

import { parentPort, workerData } from 'node:worker_threads';

const module = new WebAssembly.Module(workerData.moduleBytes);
const { maxOutput } = workerData;

parentPort.on('message', ({ id, input }) => {
  try {
    const { memory, alloc, project } = new WebAssembly.Instance(module, {}).exports;
    const ptr = alloc(input.length) >>> 0;
    if (ptr + input.length > memory.buffer.byteLength) throw new Error('input does not fit the module\'s memory');
    new Uint8Array(memory.buffer, ptr, input.length).set(input);
    const packed = BigInt.asUintN(64, project(ptr, input.length));
    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);
    if (outLen > maxOutput) throw new Error(`output of ${outLen} bytes is over the limit`);
    if (outPtr + outLen > memory.buffer.byteLength) throw new Error('output is outside the module\'s memory');
    parentPort.postMessage({ id, ok: true, output: new Uint8Array(memory.buffer.slice(outPtr, outPtr + outLen)) });
  } catch (err) {
    parentPort.postMessage({ id, ok: false, error: err.message });
  }
});
