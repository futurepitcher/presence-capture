/**
 * What a projector module declares, read from its bytes before it runs: its
 * imports and its memories. A projector may import nothing (no network, no
 * files, no clock, no randomness: nothing to reach and nothing to vary), and
 * must declare one memory with a maximum (ADR 0007).
 */

function u32(bytes, at) {
  let result = 0;
  let shift = 0;
  let byte;
  do {
    if (at >= bytes.length) throw new Error('truncated module');
    byte = bytes[at++];
    result |= (byte & 0x7f) << shift;
    shift += 7;
  } while (byte & 0x80);
  return [result >>> 0, at];
}

/** @returns {{imports: number, memories: Array<{min: number, max: number|null, memory64: boolean}>}} */
export function inspectWasm(bytes) {
  const header = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  if (header.some((b, i) => bytes[i] !== b)) throw new Error('not a WebAssembly 1.0 module');
  let imports = 0;
  const memories = [];
  let at = 8;
  while (at < bytes.length) {
    const id = bytes[at++];
    let size;
    [size, at] = u32(bytes, at);
    const end = at + size;
    if (id === 2) [imports] = u32(bytes, at);
    if (id === 5) {
      let count;
      let p;
      [count, p] = u32(bytes, at);
      for (let i = 0; i < count; i++) {
        const flags = bytes[p++];
        let min;
        let max = null;
        [min, p] = u32(bytes, p);
        if (flags & 0x01) [max, p] = u32(bytes, p);
        memories.push({ min, max, memory64: Boolean(flags & 0x04) });
      }
    }
    at = end;
  }
  return { imports, memories };
}
