# Shared cases

Rules every implementation must apply the same way **before anything reaches
disk**, written down as data so that implementations in different languages
can be held to the same answers.

| File | Rule | Reference |
|------|------|-----------|
| `exclusion.json` | What is never captured: system UI and the lock screen, the app's own windows, and the user's list (R8). Includes how the user's list is parsed | `src/exclusion.js` |
| `redaction.json` | Secrets and personal identifiers replaced before writing (CONTRACT step 3) | `src/redact.js` |
| `observations.json` | What a sensor plugin may emit: its header and observations ([ADR 0007](../../../docs/adr/0007-plugins.md)) | `src/observations.js` |
| `sessions.json` | Activity sessions, computed in memory by a reader, never stored (ADR 0008): one app and window, short interruptions taken in, idle and lock ending them | `src/sessions.js` |

The reference implementations are tested against these files in
`conformance/api/cases.test.js`. The macOS daemon tests its own against the
same files. Add a case here, not in one implementation's tests, so every
implementation picks it up.

Near-duplicate suppression (R7) is not here yet. The daemon decides a window
is unchanged by its pixels, and text-level dedupe is still to be settled in
M2.
