# Known limits

What Presence Capture 0.1 doesn't do, or does only partly, and why. Each is
here because a review found it and it was judged acceptable for this release,
or because it can't be fixed from inside the app.

## Dictation

Dictation is experimental in 0.1.

- **Where the cursor was is read a moment after the key.** At key-down and at
  release, the app in front is read at the key event itself, but its focused
  field is read through Accessibility just after, off the main thread, and
  must be read within half a second of the key event (else nothing is typed
  or kept). Moving to another field of the same app within that moment can go
  unnoticed. The dictation is then typed into the field you're in at release,
  rather than held in the panel. It's never typed into a password field: that's
  checked again just before typing. Watching every focus change as it happens
  would close this; it needs live testing, so it's left for after 0.1.
- **A paste can arrive after the clipboard is put back.** When a field doesn't
  take text through Accessibility, a dictation is pasted: the clipboard holds
  the words, ⌘V is sent, and 750 ms later your clipboard is put back (unless
  something else copied meanwhile). macOS gives no sign that a paste was read,
  so an app slower than 750 ms to read it pastes your restored clipboard
  instead. The live check measures this in TextEdit, Safari, Messages, Notes
  and Terminal (`docs/benchmarks.md`).
- **Saving your clipboard can wait on the app that copied.** Before a paste,
  every format on the clipboard is read so it can be put back, and an app that
  copied something large, or promised it, can be slow to give it. That read
  happens only while no dictation is being heard, so it never delays one's
  release or cancel, but the menu can be slow to respond meanwhile. If any
  format can't be read, the clipboard isn't touched: the words are held in the
  panel to copy instead.
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
