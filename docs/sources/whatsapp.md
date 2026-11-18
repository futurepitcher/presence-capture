# WhatsApp as a source (draft plan)

> **Status: draft, not in 0.1.** A plan and a first sensor
> ([`packages/plugins/whatsapp`](../../packages/plugins/whatsapp/README.md)),
> tested only against a synthetic database. Nothing here has run against a
> real WhatsApp install yet. The open questions at the end need answers first.

## The short version

Read WhatsApp Desktop's own message database on the Mac, **read-only**, as a
[sensor plugin](../plugins.md): **one chat per sensor**, each approved by the
person, by default **only their own messages**, text only. It goes through the
same gate as every capture (validation, exclusion, redaction, sealing), so
Pause, Forget, retention and revocation work on it unchanged.

No traffic to WhatsApp, no automation of the service, no copy of the database,
no media.

## What already happens today

Presence Capture already reads the WhatsApp window when it's in front, like any
app: its Accessibility text, then OCR. That covers what the person actually
looked at, and nothing else. Adding `whatsapp` to **Edit Excluded Apps and
Windows…** stops it. For many people that's enough, and it's the most
consent-aligned form there is: it only remembers what was on their screen.

The sensor below is a bigger step: it remembers a chat's messages whether or
not they were looked at. That's why it's per chat, off by default, and
approved by hand.

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
- It's continuous and fast (a query every 30 seconds by default).
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
varies by locale and platform, and they're history, not a stream. An importer
that reads an export through the same gate would suit backfill. It's not
drafted here.

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
- `ZWACHATSESSION.ZCONTACTJID` as the chat's id. It's the iOS name and the
  sensor relies on it; no Mac source confirmed it.
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
the people they're talking to. The design leans to the second.

1. **Off by default.** No sensor runs until it's listed in `sensors.json` and
   approved in **Approve Sensors…**, which shows the exact command.
2. **Opt in per chat.** One sensor entry per chat (`--chat`). There's no "all
   chats" switch. Approving a chat shows its id and the label it will be kept
   under.
3. **Your own messages unless you say otherwise.** `--from me` is the default.
   `--from both` keeps the other side too, and should be a deliberate choice
   per chat (open question 1).
4. **Groups are refused** unless the entry says `--allow-group`. In a group,
   other members are kept as "Member", never by name.
5. **The person names the chat.** What's kept as the window is
   `WhatsApp: <label>`, the label they wrote. The contact's WhatsApp name and
   number aren't read into the store.
6. **Changing the scope should be a new approval, and today isn't.** Pins
   cover the files a command names, not its other arguments, so editing
   `--chat`, `--label` or `--from` in `sensors.json` runs without asking
   again. Proposed: pin the whole argument list too, for every sensor (a
   small change to `pins.js` and `Pins.swift`, its own pull request).
7. **Visible.** Today the menu shows approved and waiting sensors. Planned: the
   menu lists each WhatsApp chat being captured, with a dot while it's on.
8. **Pause** holds every sensor: what it sends while held is dropped, not
   queued. Adding WhatsApp to the exclusion list drops everything this sensor
   sends too, since its observations carry the app's name.
9. **Revoke and delete, for real.** Each chat's sensor has its own name, so its
   own source (`sensor:whatsapp-<label>`). Revoking that source erases every
   message from that chat: content, keys and bytes, with a receipt, checked by
   the forensic test. A revoked message never comes back on a restart (dedupe
   by the message's id). Forget by time takes these in like any capture.
   Removing the sensor entry stops new capture; it doesn't erase what's kept.
   **Gap:** the store revokes by source today, but the app and `pcap forget`
   only revoke by time, so a person can't yet forget one chat alone. Needed
   before release: `pcap forget --source sensor:whatsapp-<label>`, and
   **Stop and Forget This Chat** in the menu, which removes the entry and
   revokes its source together.

## What's captured, and what isn't

| Captured | Not captured |
|---|---|
| Text of messages in an approved chat, with their time | Any chat not approved |
| Your messages; theirs only with `--from both` | Media: photos, voice notes, video, documents, stickers |
| Which chat, as your label | Contact names, numbers, profile photos, statuses |
| | Calls, reactions, read receipts, typing |
| | Anything before `--since` (a day before start, by default) |

Keys, tokens, emails, phone and card numbers in a message are redacted by the
gate before it's written, as for any capture.

## How it maps to the schema

Each message is one `screen` observation:

```json
{"at": "2026-11-17T09:00:00.000Z", "kind": "screen", "app": "WhatsApp", "bundle": "net.whatsapp.WhatsApp",
 "window": "WhatsApp: Alex", "text": "Me: Morning, are we still on for the demo?", "dedupe": "wa:<message id>"}
```

It lands as `screen_text`, source `sensor:<name>`, sealed under its own key.

**Two gaps, proposed in [RFC draft: sensor privacy floor](../../rfcs/0000-sensor-privacy-floor.md):**

1. **Privacy level.** Every sensor capture lands as `standard`, so any grant
   that reads `standard` (the default) can serve these messages to an agent.
   Private conversations should be `sensitive`, which no grant reads unless
   it names it. The RFC lets the *host's* configuration, never the sensor,
   raise a sensor's captures to `sensitive`. **Until it lands, don't enable
   this sensor with an agent connected**, or give agents grants whose
   `sources` leave `sensor:whatsapp*` out.
2. **Extraction.** `screen` allows `accessibility` or `ocr`, and the gate
   defaults to `ocr`. A message read from an app's own store is neither, so the
   record says `ocr` when it isn't. The RFC adds `app_store`.

A `message` capture type of its own (sender, chat, reply) would be cleaner
still. That's a bigger RFC, and isn't needed to start.

## Open questions for Christopher

1. **Whose words.** Your messages only by default, or both sides? Keeping the
   other side means storing people's words they didn't agree to have kept.
   Options: only yours; both, chat by chat; both, only with people who've said
   yes.
2. **Backfill.** Start from now (a day back by default), or import history?
   History through the database is one flag; through official exports is a
   separate importer.
3. **The privacy floor.** Ship the RFC before this sensor is announced, or
   ship the sensor marked experimental with the "no agent connected"
   warning?

Also needed from a real Mac, by whoever runs it first: the permission prompt
seen, `--list-chats` working (it confirms `ZCONTACTJID`), and a week of
capture with WhatsApp open, checking WhatsApp's files are untouched.
