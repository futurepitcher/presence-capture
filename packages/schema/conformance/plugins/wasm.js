/**
 * A minimal WebAssembly encoder, for building projector modules in tests:
 * the well-behaved one and the hostile ones the kit must refuse. No toolchain,
 * and no binaries in the repository.
 */

const leb = (n) => {
  const out = [];
  let v = n >>> 0;
  do {
    let byte = v & 0x7f;
    v >>>= 7;
    if (v !== 0) byte |= 0x80;
    out.push(byte);
  } while (v !== 0);
  return out;
};

/** Signed LEB128 of a BigInt, for i64.const. */
const sleb64 = (value) => {
  const out = [];
  let v = BigInt(value);
  for (;;) {
    const byte = Number(v & 0x7fn);
    v >>= 7n;
    const done = (v === 0n && (byte & 0x40) === 0) || (v === -1n && (byte & 0x40) !== 0);
    out.push(done ? byte : byte | 0x80);
    if (done) return out;
  }
};

const vec = (items) => [...leb(items.length), ...items.flat()];
const str = (s) => vec([...Buffer.from(s)]);
const section = (id, bytes) => [id, ...leb(bytes.length), ...bytes];

const I32 = 0x7f;
const I64 = 0x7e;
const op = {
  end: 0x0b, i32const: 0x41, i64const: 0x42, globalGet: 0x23, globalSet: 0x24, i32eqz: 0x45,
  if: 0x04, else: 0x05, loop: 0x03, br: 0x0c, void: 0x40, localGet: 0x20, drop: 0x1a,
};

export const INPUT_AT = 1024;

/** i64.const of an output's place: pointer in the high half, length in the low. */
export const packed = (ptr, len) => [op.i64const, ...sleb64((BigInt(ptr) << 32n) | BigInt(len))];

/**
 * @param {{project: number[], data?: Array<{at: number, bytes: number[]}>, memory?: {min: number, max?: number}|null,
 *   importFetch?: boolean, mutableGlobal?: boolean}} spec
 *   `project` is the body of project(ptr, len) -> i64, without its end.
 */
export function buildModule({ project, data = [], memory = { min: 1, max: 1 }, importFetch = false, mutableGlobal = false }) {
  const types = section(1, vec([
    [0x60, ...vec([[I32]]), ...vec([[I32]])],          // alloc: (i32) -> i32
    [0x60, ...vec([[I32], [I32]]), ...vec([[I64]])],   // project: (i32, i32) -> i64
    [0x60, ...vec([[I32], [I32]]), ...vec([])],        // fetch: (i32, i32) -> ()
  ]));
  const imports = importFetch ? section(2, vec([[...str('env'), ...str('fetch'), 0x00, ...leb(2)]])) : [];
  const funcs = section(3, vec([leb(0), leb(1)]));
  const memories = memory ? section(5, vec([memory.max == null ? [0x00, ...leb(memory.min)] : [0x01, ...leb(memory.min), ...leb(memory.max)]])) : [];
  const globals = mutableGlobal ? section(6, vec([[I32, 0x01, op.i32const, 0x00, op.end]])) : [];
  const base = importFetch ? 1 : 0;
  const exports = section(7, vec([
    ...(memory ? [[...str('memory'), 0x02, 0x00]] : []),
    [...str('alloc'), 0x00, ...leb(base)],
    [...str('project'), 0x00, ...leb(base + 1)],
  ]));
  const body = (code) => { const b = [0x00, ...code, op.end]; return [...leb(b.length), ...b]; };
  // i32.const takes a signed LEB128: 8192 unsigned would read back as negative.
  const code = section(10, vec([body([op.i32const, ...sleb64(INPUT_AT)]), body(project)]));
  const dataSection = data.length ? section(11, vec(data.map(({ at, bytes }) => [0x00, op.i32const, ...sleb64(at), op.end, ...vec(bytes)]))) : [];
  return new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...types, ...imports, ...funcs, ...memories, ...globals, ...exports, ...code, ...dataSection]);
}

/** A projector that returns `json` for every capture. */
export function constant(json, extra = {}) {
  const bytes = [...Buffer.from(json)];
  const at = 4096;
  return buildModule({ project: packed(at, bytes.length), data: [{ at, bytes }], ...extra });
}

/** Returns `first` the first time an instance is called, `then` after: a module that keeps state. */
export function stateful(first, then) {
  const a = [...Buffer.from(first)];
  const b = [...Buffer.from(then)];
  return buildModule({
    mutableGlobal: true,
    data: [{ at: 4096, bytes: a }, { at: 8192, bytes: b }],
    project: [
      op.globalGet, 0x00, op.i32eqz,
      op.if, I64, op.i32const, 0x01, op.globalSet, 0x00, ...packed(4096, a.length),
      op.else, ...packed(8192, b.length), op.end,
    ],
    memory: { min: 1, max: 1 },
  });
}

/** Never returns. */
export const forever = () => buildModule({ project: [op.loop, op.void, op.br, 0x00, op.end, op.i64const, 0x00] });

export { op };
