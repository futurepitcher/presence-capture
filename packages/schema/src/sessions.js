/**
 * Activity sessions (ADR 0008): computed in memory from activity captures,
 * never stored, so revoking any capture behind one just changes what's
 * computed next. The rules are cases/sessions.json, which the macOS daemon is
 * held to as well.
 */

const INTERRUPTION_MS = 30_000;

const keyOf = (a) => (a.excluded ? '\u0000excluded' : `${a.app ?? ''}\u0000${a.window ?? ''}`);

/**
 * @param {{id: string, at: string, state: 'active'|'idle'|'locked', app?: string, window?: string, excluded?: boolean}[]} activity
 *   activity captures, in the order they were captured
 * @param {{now: string}} options  the end of the last capture's time
 * @returns {{id: string, started_at: string, ended_at: string|null, capture_ids: string[]}[]}
 */
export function sessionsOf(activity, { now }) {
  const ms = (t) => Date.parse(t);
  const spans = activity.map((a, i) => ({ ...a, key: keyOf(a), end: i + 1 < activity.length ? activity[i + 1].at : now }));
  const length = (s) => ms(s.end) - ms(s.at);
  const sessions = [];
  let current = null;
  const close = (at) => {
    if (current) sessions.push({ id: current.id, started_at: current.started_at, ended_at: at, capture_ids: current.capture_ids });
    current = null;
  };

  for (let i = 0; i < spans.length;) {
    const span = spans[i];
    if (span.state !== 'active') {
      close(span.at);
      i += 1;
      continue;
    }
    if (current?.key === span.key) {
      current.capture_ids.push(span.id);
      i += 1;
      continue;
    }
    if (current) {
      // Other active captures, under the interruption length in all, then back
      // to the same app and window: taken into the session.
      let j = i;
      let total = 0;
      while (j < spans.length && spans[j].state === 'active' && spans[j].key !== current.key && total + length(spans[j]) < INTERRUPTION_MS) {
        total += length(spans[j]);
        j += 1;
      }
      if (j > i && j < spans.length && spans[j].state === 'active' && spans[j].key === current.key) {
        for (let k = i; k < j; k++) current.capture_ids.push(spans[k].id);
        i = j;
        continue;
      }
      close(span.at);
    }
    current = { key: span.key, id: `ses_${span.id}`, started_at: span.at, capture_ids: [span.id] };
    i += 1;
  }
  close(null);
  return sessions;
}
