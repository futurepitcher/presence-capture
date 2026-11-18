# WhatsApp as a source (experimental)

> **Experimental, not in 0.1.** A plan and a first sensor
> ([`packages/plugins/whatsapp`](https://github.com/futurepitcher/presence-capture/blob/main/packages/plugins/whatsapp/README.md)),
> tested only against a synthetic database. Nothing here has run against a
> real WhatsApp install yet.
>
> **Don't connect an agent while it runs.** Its captures are `standard`, the
> level every default grant reads, so any connected agent can read every
> chat it keeps, other people's words included. Until the
> [privacy floor](#how-it-maps-to-the-schema) lands, run it with no agent
> connected, or only with grants whose `sources` leave `sensor:whatsapp*` out.

## The short version

Read WhatsApp Desktop's own message database on the Mac, **read-only**, as a
[sensor plugin](../plugins.md): **every chat, both sides**, groups included,
text only, from the moment the person approves it. That's what people install
it for. They opt out chat by chat with an **exclude list**, which the sensor
reads before every query. History can be **imported**, up to a year back, and
no further than the store keeps anything. It goes through the same gate as
every capture (validation, exclusion, redaction, sealing), so Pause, Forget,
retention and revocation work on it unchanged, and one chat can be forgotten
alone.

No traffic to WhatsApp, no automation of the service, no copy of the database,
no media.

## What already happens today

Presence Capture already reads the WhatsApp window when it's in front, like any
app: its Accessibility text, then OCR. That covers what the person actually
looked at, and nothing else. Adding `whatsapp` to **Edit Excluded Apps and
Windows…** stops it. For many people that's enough, and it's the most
consent-aligned form there is: it only remembers what was on their screen.

The sensor below is a bigger step: it remembers every chat's messages whether
or not they were looked at. That's why it runs only once it's approved, with a
consent that says so in plain words, and why a chat can be excluded, and
forgotten, on its own.

## Capture routes compared

| Route | How | Verdict |
|---|---|---|
| **A. Local database, read-only** | Read `ChatStorage.sqlite`, which the Mac app keeps in its group container | **Chosen** |
| B. Official chat export | WhatsApp's own Export Chat, one chat at a time, to a `.txt` or `.zip` | A good **importer** later, not a live source |
| C. Web-client automation | `whatsapp-web.js`, wechaty's WhatsApp puppets, Baileys and the like | **Rejected** |
| D. Screen text (built in) | Accessibility and OCR of the window in front | Already there |
| E. WhatsApp Business Platform | Meta's Cloud API | Not possible: it's for business numbers, not a personal account |

**Why A.**
- It reads what WhatsApp has already decrypted and written to this Mac. Nothing
  talks to WhatsApp's servers, so there's no linked device to add, no
  automated traffic, and no account to put at risk.
- It needs no network, which keeps the project's position: no listener, no
  hosted anything, nothing leaves the Mac except through a grant.
- It's continuous and fast (a query every 30 seconds by default), and sees
  every chat the Mac app holds without the person opening any of them.
- Its risk is the schema. The database is WhatsApp's private format and can
  change in any release. The sensor checks the columns it reads every time it
  opens the file and **stops rather than guesses** when one is missing.

**Why not C.** These libraries run an unofficial client: a headless browser or
a reimplementation of the protocol logged in as a linked device. WhatsApp's
terms don't allow unofficial or automated clients, and accounts using them are
reported banned. They also hold an open session that can **send**, which a
capture tool must never be able to do, and they need the network. The earlier
wechaty idea is dropped for these reasons.

**Why B is later.** Exports are official and as explicit as consent gets (the
person picks the chat and taps Export). But they're one-off, their text format
varies by locale and platform, and they're history, not a stream. History is
imported from the same database instead (below). An export importer would
still help for messages older than what the Mac holds, and isn't drafted
here.

## What was checked, and what wasn't

Checked, from public write-ups dated October and November 2026 (each by an
individual, not WhatsApp):
- The current Mac app keeps its messages in
  `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`.
  Older Electron-era folders are stale.
- It's a Core Data SQLite database in WAL mode, **plaintext at rest** apart
  from FileVault.
- Messages are in `ZWAMESSAGE` (`ZTEXT`, `ZISFROMME`, `ZMESSAGEDATE`,
  `ZCHATSESSION`, `ZSTANZAID`, among others), chats in `ZWACHATSESSION`.
  Times are seconds since 2001-01-01.

**Not verified, and needs a real Mac:**
- `ZWACHATSESSION.ZCONTACTJID` as the chat's id, and `ZPARTNERNAME` as its
  name. They're the iOS names; no Mac source confirmed them. Without a name
  column, a chat is kept as "Chat <n>", never by its number.
- Which macOS permission the reader needs. Full Disk Access works; macOS 15
  and later may instead ask to read "data from other apps" for a group
  container. Untested.
- That a read-only open of a live WAL database sees the newest messages
  without touching WhatsApp's files. It's designed to (read-only,
  `query_only`, opened and closed each read), and the tests check the file is
  unchanged, but only against a synthetic database.
- Which `ZMESSAGETYPE` values mean what. The sensor doesn't use them: it takes
  rows with text and nothing else.
- Edited and deleted messages. An edit isn't picked up again (the row is
  already past the watermark), and a message deleted for everyone before the
  Mac received it may never be written.

## Consent

Consent here has two people in it: the person running Presence Capture, and
the people they're talking to. Capture is automatic once it's on, because
that's why it's installed; the consent is given once, plainly, and every chat
can be taken back out.

1. **One clear consent, when it's turned on.** `--install` adds the sensor to
   `sensors.json`, unapproved. Nothing is read until the person approves it
   from the menu (**Approve 1 Sensor…**), which for this sensor asks
   **Capture your WhatsApp chats?** and says: every chat, both sides and
   groups, other people's words included; on this Mac, sealed, for as long as
   **Keep Captures For** says; never sent; how to exclude a chat, pause, and
   forget one; and not to connect an agent while it's experimental. Approving
   it is the consent. It also reminds them the people they talk to haven't
   agreed by their installing it.
2. **Labelled experimental.** The command must contain `--experimental` or
   the sensor refuses to start. `--install` writes it, so it's no extra step
   for the person, but it's in the command they approve, and the sensor says
   so on standard error each time it starts.
3. **Every chat, unless excluded.** **Exclude WhatsApp Chats…** in the menu
   opens the list (`whatsapp-exclude.txt` beside the store): one chat a line,
   its name as WhatsApp shows it or its id, matched whole and in any case. The
   sensor reads it before every query, so a chat added is skipped from the
   next one, about 30 seconds. A chat taken off the list starts from then;
   what arrived while it was excluded is never read. A list that exists but
   can't be read means nothing is read until it can be. Editing the list
   doesn't need approving again: it isn't in the command, so it isn't pinned.
4. **Both sides by default.** `--from me` keeps only the person's own
   messages, for those who'd rather.
5. **Groups, without naming members.** In a group, other members are kept as
   "Member". The chat's own name is kept, so a message is read in context;
   numbers and profile photos aren't read into the store.
6. **Changing the command should be a new approval, and today isn't fully.**
   Pins cover the files a command names, not its other arguments, so adding
   `--history-days` in `sensors.json` runs without asking again. Proposed: pin
   the whole argument list too, for every sensor (a small change to `pins.js`
   and `Pins.swift`, its own pull request).
7. **Pause** holds it with every sensor: what it sends while held is dropped,
   not queued. Adding `whatsapp` to **Edit Excluded Apps and Windows…** drops
   everything it sends at the gate, and `whatsapp: <chat name>` drops one
   chat there.
8. **Forget, for real.** Each chat's captures carry their own app,
   `net.whatsapp.WhatsApp.chat-<n>` (the chat's row in WhatsApp's database,
   which means nothing off this Mac), so one chat is revoked and erased alone:
   `pcap forget --source net.whatsapp.WhatsApp.chat-12`, as `--list-chats`
   names it. Everything the sensor kept goes with `--source sensor:whatsapp`.
   Content, keys and bytes are erased with a receipt, and a forgotten message
   never comes back on a restart (dedupe by the message's id). Forget by time
   and retention take these in like any capture. Excluding a chat stops new
   capture; it doesn't erase what's kept. **Gap:** excluding a chat doesn't
   yet offer to forget it in the app. Planned: a **Forget This Chat Too**
   choice beside the exclude list, which the app can do once it reads the
   chat names (below).

## What's captured, and what isn't

| Captured | Not captured |
|---|---|
| Text of messages in every chat not excluded, with their time | Chats on the exclude list |
| Both sides (yours only with `--from me`) | Media: photos, voice notes, video, documents, stickers |
| The chat's name, as WhatsApp shows it | Numbers, profile photos, statuses; group members' names |
| | Calls, reactions, read receipts, typing |
| | Anything older than a day, unless history is imported |

Keys, tokens, emails, phone and card numbers in a message are redacted by the
gate before it's written, as for any capture.

## Importing history

History is opt-in, bounded and still read-only.

- **Opt-in.** `--history-days <n>` in the sensor's command, or `--since
  <time>` for an exact start, for every chat not excluded. Without either, it
  starts a day back.
- **Bounded twice.** At most 365 days back; the sensor refuses more. And no
  further than the store keeps anything: an imported message is a capture
  like any other, so retention (**Keep Captures For**, a year by default, or
  **Indefinitely**) erases one older than that within the hour, and once
  retention has cut a range, the store refuses anything stamped inside it. To
  keep a longer history, raise retention first, knowingly.
- **Once.** Each message carries its own id as `dedupe`, so restarting, or
  importing again, adds nothing, and a message that was forgotten or aged out
  never comes back.
- **Only what the Mac holds.** The Mac app may not have a chat's full history
  (it's a linked device). Older messages would need the export importer.
- **Same gate.** Imported messages are excluded, redacted and sealed like live
  ones, and Forget by time takes them in by when they were sent.

A year back, every chat, is a lot to keep at once. Whether set-up should offer
to import history is still to decide.

## How it maps to the schema

Each message is one `screen` observation:

```json
{"at": "2026-11-17T09:00:00.000Z", "kind": "screen", "app": "WhatsApp", "bundle": "net.whatsapp.WhatsApp.chat-12",
 "window": "WhatsApp: Alex", "text": "[Alex] Me: Morning, are we still on for the demo?", "dedupe": "wa:<message id>"}
```

It lands as `screen_text`, source `sensor:<name>`, app
`net.whatsapp.WhatsApp.chat-12`, sealed under its own key. A `screen_text`
capture keeps its text, not its window, so the chat's name is in the text.
The app field carrying the chat is a stretch of what `bundle` means; it's
what lets one chat be forgotten with today's revocation scopes.

**Two gaps, proposed in [RFC draft: sensor privacy floor](https://github.com/futurepitcher/presence-capture/blob/main/rfcs/0000-sensor-privacy-floor.md):**

1. **Privacy level.** Every sensor capture lands as `standard`, so any grant
   that reads `standard` (the default) can serve these messages to an agent.
   Private conversations should be `sensitive`, which no grant reads unless
   it names it. The RFC lets the *host's* configuration, never the sensor,
   raise a sensor's captures to `sensitive`. It's future work, not in this
   change. **Until it lands, the sensor ships as experimental**: don't
   connect an agent while it runs, or give agents grants whose `sources`
   leave `sensor:whatsapp` out.
2. **Extraction.** `screen` allows `accessibility` or `ocr`, and the gate
   defaults to `ocr`. A message read from an app's own store is neither, so the
   record says `ocr` when it isn't. The RFC adds `app_store`.

A `message` capture type of its own (sender, chat, reply) would be cleaner
still. That's a bigger RFC, and isn't needed to start.

## Decided (2026-11-18)

1. **Whose words:** both sides.
2. **History:** importable, bounded as above.
3. **Release:** ships as experimental, with the "don't connect an agent"
   warning, ahead of the privacy-floor RFC.
4. **Which chats:** all of them, automatically once it's on, unless the
   person excludes a chat. This replaced one sensor per chat, approved one at
   a time.
5. **How long:** **Keep Captures For** defaults to a year, chosen in the
   set-up window, which also offers **Indefinitely**. That's the app's one
   retention setting, so it covers every capture type, not only WhatsApp.

## Still needed

From a real Mac, by whoever runs it first: the permission prompt seen,
`--list-chats` working (it confirms `ZCONTACTJID` and `ZPARTNERNAME`), and a
week of capture with WhatsApp open, checking WhatsApp's files are untouched.

To be automatic from install, not one command after it: the reader inside the
app (a Swift port of this sensor, about 150 lines over SQLite, which the app
already links), or the app shipping Node and this script. Either way the
consent above moves into the set-up window as its own step.

Before it leaves experimental: the privacy floor, **Forget This Chat Too**
beside the exclude list, and pins that cover a command's arguments.
