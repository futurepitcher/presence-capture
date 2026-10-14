# Known limits

What Presence Capture 0.1 doesn't do, or does only partly, and why. Each is
here because a review found it and it was judged acceptable for this release,
or because it can't be fixed from inside the app.

## Dictation

- **A paste can arrive after the clipboard is put back.** When a field doesn't
  take text through Accessibility, a dictation is pasted: the clipboard holds
  the words, ⌘V is sent, and 750 ms later your clipboard is put back (unless
  something else copied meanwhile). macOS gives no sign that a paste was read,
  so an app slower than 750 ms to read it pastes your restored clipboard
  instead. The live check measures this in TextEdit, Safari, Messages, Notes
  and Terminal (`docs/benchmarks.md`).
- **Input Monitoring is a keyboard permission.** Holding a key needs it. The
  event tap is listen-only and asks for modifier changes alone, so it never
  sees what's typed, but the permission macOS grants is broader than that.
  It's asked for only when dictation is turned on.

## Connecting an agent

- **Connections take turns; the agents' own apps don't.** `pcap connect` and
  Connect an Agent… hold a lock while they check and write a client's config,
  so they never write over each other. An agent's own app (Claude Desktop,
  Cursor, Claude Code) doesn't take that lock: a change it makes in the
  moment between the check and the write can be lost. The config is copied
  aside first.
