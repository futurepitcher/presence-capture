# WhatsApp as a source (experimental)

> **Experimental, not in 0.1.** Built into the Mac app (**Capture WhatsApp**,
> in the set-up window and the menu), with the same reader as a
> [sensor plugin](https://github.com/futurepitcher/presence-capture/blob/main/packages/plugins/whatsapp/README.md)
> for other hosts. Tested only against a synthetic database. Nothing here has
> run against a real WhatsApp install yet.
>
> **Don't connect an agent while it runs.** Its captures are `standard`, the
> level every default grant reads, so any connected agent can read every
> chat it keeps, other people's words included. Until the
> [privacy floor](#how-it-maps-to-the-schema) lands, run it with no agent
> connected, or only with grants whose `sources` leave `whatsapp` (and
> `sensor:whatsapp*`) out.

## The short version

Read WhatsApp Desktop's own message database on the Mac, **read-only**, inside
the app: **every chat, both sides**, groups included, text only, from the
moment the person turns it on in the set-up window, which is the consent. From
then on it runs by itself; that's what people install it for. They opt out
chat by chat with an **exclude list**, read before every read. Past messages
can be **imported** in the same step, up to a year back and **off by
default**, and no further than the store keeps anything. It goes through the same gate as
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

Capture WhatsApp is a bigger step: it remembers every chat's messages whether
or not they were looked at. That's why it's off until the person turns it on,
with a consent that says so in plain words, and why a chat can be excluded,
and forgotten, on its own.

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
- It's continuous and fast (a read every 30 seconds), and sees
  every chat the Mac app holds without the person opening any of them.
- Its risk is the schema. The database is WhatsApp's private format and can
  change in any release. The reader checks the columns it reads every time it
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
  container, and may hide the file from the app until it's allowed (so it
  could look "not installed"). The app sends the person to Full Disk Access
  when a read is refused. Untested.
- That a read-only open of a live WAL database sees the newest messages
  without touching WhatsApp's files, and still reads when WhatsApp is closed
  without leaving files in its folder. It's designed to (read-only,
  `query_only`, opened and closed each read), and the tests check both, but
  only against a synthetic database.
- Which `ZMESSAGETYPE` values mean what. The reader doesn't use them: it takes
  rows with text and nothing else.
- Edited and deleted messages. An edit isn't picked up again (the row is
  already past the watermark), and a message deleted for everyone before the
  Mac received it may never be written.

## Consent

Consent here has two people in it: the person running Presence Capture, and
the people they're talking to. Capture is automatic once it's on, because
that's why it's installed; the consent is given once, plainly, and every chat
can be taken back out.

1. **One clear consent, when it's turned on.** The set-up window has a
   **WhatsApp (optional, experimental)** step, and the menu has **Capture
   WhatsApp (Experimental)**. Either asks **Capture your WhatsApp chats?** and
   says: every chat, both sides and groups, other people's words included; on
   this Mac, sealed, for as long as **Keep Captures For** says; never sent;
   how to exclude a chat, pause, and forget one; and not to connect an agent
   while it's experimental. It also reminds them the people they talk to
   haven't agreed by their installing it. Agreeing is the consent; nothing is
   read before it. Turning it off in the menu stops it at once.
2. **Labelled experimental**, in the step, the menu item and the consent.
3. **Then automatic.** Once on, it reads every 30 seconds, from launch, with
   nothing more to do. If macOS hasn't let the app read WhatsApp's files, it
   says so and opens Full Disk Access; it starts by itself once allowed.
4. **Every chat, unless excluded.** **Exclude WhatsApp Chats…** in the menu
   opens the list (`whatsapp-exclude.txt` beside the store): one chat a line,
   its name as WhatsApp shows it or its id, matched whole and in any case.
   It's read before every read, so a chat added is skipped from the next one,
   about 30 seconds. A chat taken off the list starts from then; what arrived
   while it was excluded is never read. A list that exists but can't be read
   means nothing is read until it can be.
5. **Both sides.** The plugin's `--from me` keeps only the person's own
   messages; the app has no such switch yet.
6. **Groups, without naming members.** In a group, other members are kept as
   "Member". The chat's own name is kept, so a message is read in context;
   numbers and profile photos aren't read into the store.
7. **Pause** holds it with everything else: what's written while held is
   passed over, not kept later. Adding `whatsapp` to **Edit Excluded Apps and
   Windows…** drops all of it at the gate, and a chat's name there drops that
   chat.
8. **Forget, for real.** Each chat's captures carry their own app,
   `net.whatsapp.WhatsApp.chat-<n>` (the chat's row in WhatsApp's database,
   which means nothing off this Mac), so one chat is revoked and erased alone.
   **Forget a WhatsApp Chat…** in the menu picks it by name, erases what was
   kept with a receipt, and (ticked by default) adds it to the exclude list so
   it isn't read again. From Terminal: `pcap forget --source
   net.whatsapp.WhatsApp.chat-12`; everything with `--source whatsapp`.
   Content, keys and bytes are erased, and a forgotten message never comes
   back, even by importing history again (dedupe by the message's id). Forget
   by time and retention take these in like any capture.

The [sensor plugin](https://github.com/futurepitcher/presence-capture/blob/main/packages/plugins/whatsapp/README.md)
keeps the same reader for other hosts, approved through **Approve Sensors…**
with the same consent. On a Mac, use the built-in one: running both notes
every message twice, and the app says so when both are set up.

## What's captured, and what isn't

| Captured | Not captured |
|---|---|
| Text of messages in every chat not excluded, with their time | Chats on the exclude list |
| Both sides | Media: photos, voice notes, video, documents, stickers |
| The chat's name, as WhatsApp shows it | Numbers, profile photos, statuses; group members' names |
| | Calls, reactions, read receipts, typing |
| | Anything sent before it was turned on, unless history is imported |

Keys, tokens, emails, phone and card numbers in a message are redacted by the
gate before it's written, as for any capture.

## Importing history

History is opt-in, bounded and still read-only.

- **Offered once, off by default.** Beside **Capture WhatsApp…**, the set-up
  step offers **Also bring in past messages**: None (the default), 30 days,
  90 days or 1 year, from every chat not excluded. From the menu, the consent
  offers the same, with none chosen. The plugin takes `--history-days <n>`.
- **Bounded twice.** At most 365 days back. And no further than the store
  keeps anything: the choices stop at **Keep Captures For** (a year by
  default, or **Indefinitely**), since retention would erase anything older
  within the hour, and once retention has cut a range, the store refuses
  anything stamped inside it. To keep a longer history, raise retention first,
  knowingly.
- **Once.** Each message carries its own id as `dedupe`, so restarting, or
  importing again, adds nothing, and a message that was forgotten or aged out
  never comes back.
- **Only what the Mac holds.** The Mac app may not have a chat's full history
  (it's a linked device). Older messages would need the export importer.
- **Same gate.** Imported messages are excluded, redacted and sealed like live
  ones, and Forget by time takes them in by when they were sent.

## How it maps to the schema

Each message is one `screen` observation:

```json
{"at": "2026-11-17T09:00:00.000Z", "kind": "screen", "app": "WhatsApp", "bundle": "net.whatsapp.WhatsApp.chat-12",
 "window": "WhatsApp: Alex", "text": "[Alex] Me: Morning, are we still on for the demo?", "dedupe": "wa:<message id>"}
```

It lands as `screen_text`, source `whatsapp` (`sensor:<name>` from the plugin), app
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
   leave `whatsapp` out.
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
6. **Install:** built into the app, in Swift (`CaptureCore/WhatsApp.swift`,
   SQLite the app already links), so nothing else is installed and no Node is
   shipped. Turned on in the set-up window, with its consent, and automatic
   from then.
7. **History at set-up:** offered in the same step, off by default, up to a
   year (and no further than retention keeps), every chat but the excluded.

## Still needed

From a real Mac, by whoever runs it first:
- The permission: whether macOS asks to read "data from other apps", needs
  Full Disk Access, or hides the file until one is given.
- The chat columns: that chats show by name in **Forget a WhatsApp Chat…**
  (it confirms `ZCONTACTJID` and `ZPARTNERNAME`).
- A week of capture with WhatsApp open and closed, checking WhatsApp's files
  are untouched and new messages arrive within a minute.
- A history import of a year on a busy account: how long it takes, and that
  the app stays responsive meanwhile.

Before it leaves experimental: the privacy floor, and pins that cover a
plugin command's arguments.
