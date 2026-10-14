# FAQ

Short answers for someone trying Presence Capture or sizing it up. Each one
links to the page with the detail. Where the answer is "not yet" or "no", it
says so.

## Trust and privacy

### Has it been audited?

No. It hasn't been independently audited. Codex and Claude, two AI reviewers,
have reviewed the code. That isn't an outside security firm, and it isn't a
substitute for one.

What you can check yourself: the store is held to a public conformance suite, so
claims such as "Forget erases" are tests you can run. See
[How it's checked](revocation.md#how-its-checked), [threat-model.md](threat-model.md)
and [verify.md](verify.md), which shows how to check that a download is the one
GitHub built. If you find a hole, see
[How do I report a vulnerability?](#how-do-i-report-a-vulnerability)

### Does anything leave my Mac?

Not from your captures. The app has no account, no telemetry and no server, and
neither the app nor `pcap-mcp` opens a network listener. Two requests exist, and
both are small:

- **Check for Updates…** asks GitHub for the latest release:
  `GET https://api.github.com/repos/futurepitcher/presence-capture/releases/latest`.
  It happens only when you choose it. The request carries no captures. GitHub sees
  your IP address and the usual request headers. If a newer release exists, the
  app offers to open its page in your browser
  ([`Updates.swift`](https://github.com/futurepitcher/presence-capture/blob/main/packages/daemon/Sources/PresenceCapture/Updates.swift)).
- **A speech model, once, on macOS 26.** When hearing first starts, and the speech
  model for your language isn't on the Mac, the app asks macOS to install it, and
  macOS downloads it from Apple. The app names only the language. Recognition runs
  on the device and never falls back to a network service
  ([ADR 0004](adr/0004-apple-on-device-models.md)).

Two things sit outside the app. An agent you connect reads what its grant allows,
and what it does next is up to the agent, including whether it sends the text to a
model provider. Presence Capture can't see or control that. And a sensor plugin is
a program running as you ([plugins.md](plugins.md)). Detail:
[tools.md](tools.md), [connect.md](connect.md).

### What does it capture?

Every 5 seconds, unless it's paused, the screens are asleep, the Mac is locked or
another user has it:
- the text of each on-screen window of the front app, read from the app's own
  Accessibility text where it exposes enough, and by Vision OCR otherwise;
- on macOS 26, the words the microphone and the Mac's audio output carry,
  transcribed on the device;
- the app and window in front, and whether you're active, idle or locked.

It keeps text, never screenshots or audio
([ADR 0005](adr/0005-text-first-capture.md)). The microphone is off until you
allow it. What the Mac plays is on by default, on macOS 26. Detail:
[quickstart.md](quickstart.md#what-it-captures).

### What does it not capture?

- **Apps and windows you exclude.** **Edit Excluded Apps and Windows…** opens your
  list, one line each. A line matches an app's name or a window's title, in any
  case. An excluded window is never read, so nothing of it exists to redact. Its
  time still passes, and activity keeps only the state.
- **System screens.** The lock screen, password and Touch ID prompts, and
  notifications.
- **Presence Capture's own windows.**
- **Password fields, through Accessibility.** A secure text field's value is
  never fetched. But when a window has to be read by OCR, what's drawn is read:
  a password field shows dots, but one shown in clear can be captured.
- **But exclusions don't reach ambient audio.** They match apps and windows, so they
  don't reach what the Mac plays or the microphone hears. Pause, or turn hearing
  off, to keep a call out.
- **Anything while it's paused,** or while the list can't be read.

Before anything is written, secrets (private keys, tokens, API keys,
`password=…`) and personal identifiers (emails, card and phone numbers, IP
addresses) in captured text are replaced with labels such as `[API_KEY]`.
Redaction matches known patterns, so a secret in a shape it doesn't know isn't
caught. It covers the text, not the record: a page's full URL is kept as it
was, in plain text, and stays after Forget. The order of
steps is in [CONTRACT.md](https://github.com/futurepitcher/presence-capture/blob/main/packages/daemon/CONTRACT.md#write-path).

### What about other people on a call or in the room?

The microphone hears everyone near you. They haven't agreed to it because you
installed this, and recording others is governed by law where you are. Telling
them and getting their consent is yours to do. The app lets you turn the
microphone and the Mac's audio off, and keeps everything on the Mac, but it can't
resolve consent for you. The microphone stays off until you turn it on.

### Is my data encrypted?

The content is. Each capture's text is sealed with AES-256-GCM under a key of its
own. That key is wrapped by a master key in your Keychain, on this Mac only, never
synced. The record isn't sealed: when something was captured, its type, the app,
the URL where the app could tell, and its privacy level stay readable in the store
file. That's on purpose. It lets you audit what was captured and read after the
content is gone. Detail:
[What is stored, and how it's sealed](revocation.md#what-is-stored-and-how-its-sealed).

### Can a web page trick my agent into acting on my screen text?

It can try. Any page you look at can put text on your screen, and the app captures
it faithfully. Every capture reaches an agent inside a wrapper that marks it as
untrusted data, and the server tells the client so. That helps a careful client. It
can't stop one that treats retrieved text as instructions. This is an open
problem, not a feature being held back ([ADR 0001](adr/0001-serving-trust-boundary.md)
§6.2). The server itself is read-only and local-only, which limits what it can be
made to do. Detail: [threat-model.md](threat-model.md), [tools.md](tools.md).

### What does dictation do, and what does it keep?

On macOS 26, if you turn it on, holding a key and speaking types the words where
the cursor is, transcribed on this Mac. It's experimental in 0.1 and off until
you choose it. It needs the microphone, Input Monitoring for the key (the app
watches that one key, never what you type) and Accessibility to type. It never
types into a password field. With **Remember What I Dictate** (on by default),
what you said is kept as a transcript, sealed and forgotten like any other
capture, but never from an excluded app or window or a password field. When a
field won't take text directly, the words are pasted: your clipboard holds them
for up to 750 ms, then gets back what it held. See
[known-limits.md](known-limits.md#dictation).

## Your data

### What happens when I Forget?

In one transaction, the sealed text, the sealed bytes and the wrapped key of
every capture in the range are deleted, with everything derived from them. From
then on no agent can read them, and a late capture stamped in that range is
refused. The write-ahead log is then truncated so the old bytes leave the disk. A
receipt records what was erased and when.

Forget doesn't reach copies an agent already read, or backups made before it. It
leaves the record that a capture happened. Detail:
[revocation.md](revocation.md).

### How long are captures kept?

14 days. **Keep Captures For** offers 1 day, 7, 14, 30, 90 and 1 year. Retention
is a scheduled Forget: it runs at launch and every hour, and writes the same
receipts. A shorter period erases at once, so the app asks first. Detail:
[Retention](revocation.md#retention-is-a-scheduled-revocation).

### How do I delete everything?

Two ways, depending on what you want.

**Erase the captures, keep the app.** Choose **Pause** in the menu. Then forget
the last 24 hours, and have retention erase everything older:

```sh
"/Applications/Presence Capture.app/Contents/MacOS/pcap" forget 24h
```

Then choose **Keep Captures For**, then **1 Day**, and confirm. Choosing the
period it already has does nothing, so if it's already **1 Day**, choose a
longer period first, then **1 Day** again. Last, check that both erasures
finished:

```sh
"/Applications/Presence Capture.app/Contents/MacOS/pcap" check
```

It ends `erasure: complete`. If it says `pending`, an agent's server is reading:
run it again in a moment. Both steps erase from disk, with receipts. With
Homebrew, `pcap` is on your `PATH`. Set the period back afterward if you want a
longer one, and choose **Resume**.

**Remove everything.** Quit the app, then delete its folder, then the Keychain
items that hold its key:

```sh
rm -rf "$HOME/Library/Application Support/Presence Capture"
```

In Keychain Access, search for `ai.presenceos.capture.master-key` and delete the items under
it. Delete the folder first: a store with no key can't be opened. Deleting files
isn't a Forget. It doesn't change a Time Machine backup. Deleting the key does make
a surviving copy of the store unreadable, unless a copy of your Keychain was kept
too. Also remove the app's entry from each agent
([connect.md](connect.md#disconnect)). If you set `PRESENCE_CAPTURE_HOME`,
delete that folder instead.

### Can I browse what it captured?

Not in 0.1. The menu shows counts, never content: **Agents Read…** and `pcap
egress` list what each agent was given, by day, tool and kind. To read your
captures, connect an MCP client and ask it ([quickstart.md](quickstart.md),
[tools.md](tools.md)).

### How much disk and CPU does it use?

The measured numbers are in [benchmarks.md](benchmarks.md) as they're recorded.
The seven-day soak (CPU, memory and store growth) is still to come, so there's no
published figure to quote. The design targets are under 1 GB a month of storage
([ADR 0005](adr/0005-text-first-capture.md)), and a memory budget of 250 MB for the
app ([ADR 0008](adr/0008-recall-indexes-in-memory.md)).

## Agents

### Which agents does it work with?

Any MCP client. **Connect an Agent** sets up Claude Code, Claude Desktop and
Cursor in one step, and shows the change to their settings before it makes it.
Other clients take a config entry by hand. Detail: [connect.md](connect.md).

### What can an agent read, and can it change anything?

It reads through a grant, and with no grant it gets an error, not an empty answer.
A grant limits privacy level, capture types, sources and a time window, and it
expires. Connect gives an agent standard captures of every type, for 30 days.
`sensitive` and `excluded` captures need an explicit grant, and `sacred_mode`
can't be granted at all.

It can't change anything. The server has six read-only tools. The macOS server
opens the store under an SQLite rule that refuses every write except an egress
record, and it listens on no socket. Every read is recorded in a hash-chained log,
and **Agents Read…** shows counts from it. Detail: [tools.md](tools.md),
[connect.md](connect.md#see-what-an-agent-has-read).

### How does search work?

By keyword. `search` ranks captures with BM25 over an index held in memory, never
on disk ([ADR 0008](adr/0008-recall-indexes-in-memory.md)). It's strong when your
words match the text and weaker when you paraphrase. On the project's eval (30 days,
50 questions), recall at 5 was 100% on the 25 keyword questions and 60% on the 25
paraphrased ones ([benchmarks.md](benchmarks.md)).

Search by meaning was measured with Apple's on-device embeddings and was worse than
keyword search alone (15 of 50, against 40 of 50), so 0.1 doesn't ship it. Work on a
stronger model is parked for 0.2, and it ships only if it beats keyword search on
the same eval.

## Compatibility

### Which Macs and macOS versions does it run on?

**macOS:** 14 or later for the screen text and the activity. Hearing, which means
the microphone and what the Mac plays, needs macOS 26, for Apple's SpeechAnalyzer.
On macOS 14 or 15 the app reads the screen and notes your activity, and doesn't
listen.

**Intel:** not from a release. Releases are for Apple silicon: the release runner
is arm64, and an Intel build would ship untested. On an Intel Mac, build from
source. That needs Xcode 26 or later ([building.md](building.md)).

### What about Windows or Linux?

The Mac version ships first, and Windows follows once it has
([ROADMAP.md](https://github.com/futurepitcher/presence-capture/blob/main/ROADMAP.md)). The schema, the conformance suite and the reference
MCP server run on any OS with Node 22.13 or later and no other dependency.
`packages/schema/bin/replay-fixture.js` fills a store with a synthetic day, so you
can try them without a Mac ([CONTRIBUTING.md](https://github.com/futurepitcher/presence-capture/blob/main/CONTRIBUTING.md)).

## The project

### How do I report a vulnerability?

Privately, through a GitHub security advisory: the **Report a vulnerability**
button under the Security tab of the repository. Don't open a public issue for
anything that could expose captured data. Expect an acknowledgement within 5
working days. Revoked content you can recover from the store's files is the most
valuable bug you can report. [SECURITY.md](https://github.com/futurepitcher/presence-capture/blob/main/SECURITY.md) lists what's in scope
and the limits already documented.

### What's the license?

Apache-2.0, chosen over MIT for its explicit patent grant. The pledge: the core
stays Apache-2.0, with no relicensing and no contributor license agreement, and
nothing paid ever gates capture, memory or erasure
([LICENSE](https://github.com/futurepitcher/presence-capture/blob/main/LICENSE), [GOVERNANCE.md](https://github.com/futurepitcher/presence-capture/blob/main/GOVERNANCE.md)).
