# Known limits

What Presence Capture 0.1 doesn't do, or does only partly, and why. Each is
here because a review found it and it was judged acceptable for this release,
or because it can't be fixed from inside the app.

## Capture

- **Exclusions don't reach ambient audio.** The exclusion list matches app
  names and window titles, so it governs what's read from the screen, activity
  and dictation. What the Mac plays, and what the microphone hears, isn't tied
  to a window: a call in an excluded app is still heard. Pause, or turn hearing
  off in the menu, to keep it out. If the list can't be read, nothing is
  captured at all, hearing included, until it can be.
- **OCR reads what's drawn.** Accessibility text skips secure text fields.
  When a window's text has to be read by OCR instead, whatever is drawn is
  read: a password field normally shows dots, but one shown in clear (a "show
  password" option) can be captured. Exclude the app or window to keep it out.
- **An element partly in view is read whole.** Accessibility text is kept for
  what's inside the window, and a text area only as far as it's scrolled into
  sight; a text area whose visible part can't be read keeps nothing. But a
  label or a cell that's only partly in view is read whole.
- **A page's address is kept, without its query.** The record of a capture
  keeps the page's scheme, host and path, redacted like text, in plain
  metadata that stays after Forget. Its query and fragment, where tokens
  usually are, are never kept; a secret in the path itself, in a shape
  redaction doesn't know, would be. A store made before 0.1.0 has its old
  addresses cut the same way when it's first opened (migration 011), but a
  pattern inside an old path, an email say, isn't redacted there: Forget that
  stretch to erase it.
- **Speech that runs into a forgotten stretch.** An utterance is stamped when it
  began. One that began just before the stretch you forgot, and ran on into
  it, is kept: at most the length of one utterance.
- **Every capture is `standard`.** The privacy level doesn't yet tell secrets
  from ordinary text. Exclusion, redaction and a grant's types, sources and
  time window do that work (ADR 0001 §6.3).

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

## Agents and the log

- **A denied read isn't logged.** A call with no grant, or an expired or
  revoked one, gets an explicit denial, never an empty answer, but 0.1 doesn't
  write the denial to the egress log, as ADR 0001 says it should: each record
  in the log names a grant, and a denial has none to name. Agents Read… and
  `pcap egress` show what was served, not what was refused.
- **The log counts what `pcap-mcp` loaded, too.** Its search index is built in
  memory from the rows its grant admits, recorded as tool `index`, so the log
  lists more rows than an agent was shown. What it was shown is in the records
  for the tools it called.
- **An agent that can run commands can run `pcap`.** `pcap` trusts whoever
  runs it as you, and an agent with a shell tool runs as you: it could issue
  itself a wider grant, or Forget (ADR 0001 §6.1, the threat model's "another
  process running as you"). Agents Read… shows every grant. Give an agent a
  shell only where you'd give it your account.
- **A client can make its own server work hard.** `pcap-mcp` puts no limit on
  how much a request asks for (a very long query, or many at once) beyond each
  grant's rows a read. Only the client that started it waits on it.
- **The log is evidence, not a lock.** It's hash-chained, and its triggers
  refuse changes, but it lives in your store's file: a program running as you
  that can write that file can rewrite it, and recompute the chain. `pcap
  check` finds a change made without doing that.

## Keys and logs

- **A store needs its own key.** The key is in your login Keychain, on this Mac
  only. On a new Mac, or after the Keychain is reset, a store copied across
  can't be opened, and the app says so rather than making a new key over it:
  restore the Keychain from the same backup as the store, or move the store
  aside to start a new one.
- **The app's log keeps counts after a Forget.** `logs/capture.log` holds
  counts and states, never what was captured (how many captures a Forget
  took, that a dictation was kept). Those lines aren't erased with what they
  count.
