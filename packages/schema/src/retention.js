/**
 * Run a store's retention on a schedule (ADR 0003). Each tick is one
 * `store.retain()`: a revocation with reason 'retention' when anything has
 * aged out, nothing otherwise.
 *
 * @param {object} store  a store from openStore()
 * @param {{days: number, everyMs?: number, now?: () => Date, onRun?: (result: object|null) => void}} options
 * @returns {{stop: () => void}}
 */
export function scheduleRetention(store, { days, everyMs = 3_600_000, now = () => new Date(), onRun }) {
  const timer = setInterval(() => {
    const result = store.retain({ days, now: now() });
    onRun?.(result);
  }, everyMs);
  // A schedule alone never keeps a process alive.
  timer.unref?.();
  return { stop: () => clearInterval(timer) };
}
