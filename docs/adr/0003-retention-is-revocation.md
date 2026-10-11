# ADR 0003: Retention is a scheduled revocation

## Status

**Accepted** — 2026-10-10. Implemented as `store.retain()` and
`scheduleRetention()`. Tested in `conformance/retention.test.js` (R12).

## Context

A capture store grows without bound unless something removes old content.
The usual answer is a delete on a timer. Here that would be a second removal
path beside revocation, and R2 says revocation is the only one, because only
it leaves a record and propagates to derived data with receipts.

## Decision

Retention is a revocation:
- `scope_kind = time_range`, from the epoch to `now − days`;
- `reason = 'retention'`.

It cascades through `derived_from` (R10), prunes projections with receipts
(R3), and erases content with an erasure receipt (R11), exactly as a user's
revocation does.

- `store.retain({ days })` runs it once. It returns `null`, and writes
  nothing, when no unrevoked capture is old enough. An hourly schedule
  therefore doesn't fill the log with empty revocations.
- `scheduleRetention(store, { days, everyMs })` runs it on an interval, hourly
  by default. The timer never keeps a process alive by itself.
- The period is required and must be positive. The native apps default to 14
  days, the window PresenceVoice runs with, and let the user change it.

## Consequences

- One removal mechanism. Anything that leaves the store has a revocation row,
  a reason and receipts. The user can see that retention removed last
  month's content, and when.
- Retention reaches derived artifacts whose source expired, even when the
  derived capture itself is newer. A transcript goes with its audio.
- A capture captured exactly at the cutoff is included; the range is
  inclusive.
- Retention can't be undone, any more than a revocation can.
