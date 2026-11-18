# whatsapp (experimental)

A [sensor plugin](../../../docs/adr/0007-plugins.md) that notes the text
messages of **every** WhatsApp chat on this Mac, both sides, read
**read-only** from WhatsApp Desktop's own database. Chats the person lists
are never read. The plan, the consent model and what's unverified are in
[docs/sources/whatsapp.md](../../../docs/sources/whatsapp.md). Read it before
running this.

> **On a Mac, use the app's built-in reader instead:** Capture WhatsApp, in
> the set-up window and the menu. It's the same reading in Swift, with no Node
> to install, and runs by itself once turned on. Running both notes every
> message twice. This plugin stays as the reference and for other hosts.

> **Experimental. Don't connect an agent while it runs.** Its captures are
> `standard`, so any agent with a default grant can read your chats,
> including other people's words. Tested only against a synthetic database.
> Its command must include `--experimental`, or it won't start; `--install`
> writes it for you.

- Every chat, groups included, both sides, from the moment it's approved.
- Chats on the exclude list are never read, by name or id. A chat added to it
  is skipped from the next read.
- `--from me` keeps only your own messages, if you'd rather.
- History only when asked: `--history-days <n>` (up to 365), and kept no
  longer than the store's retention (a year unless you chose otherwise).
- Text only. No media, numbers or profile photos. In a group, other members
  are "Member", never named.
- No network, no writes, no copy of the database. It stops if the database
  isn't the shape it knows.

## Set up

```sh
node sensor.mjs --install    # adds it to sensors.json, unapproved, and makes the exclude list
```

Then, in Presence Capture's menu, **Approve 1 Sensor…** shows what it keeps
(every chat, both sides, how long) and asks once. Approving it is the consent.
Nothing is read before that.

Reading the database needs permission (Full Disk Access, or macOS's prompt to
read another app's data). Which one is still to be checked on a real Mac.

## Skip a chat, forget a chat

```sh
node sensor.mjs --list-chats    # name, id, message count, and the source to forget it by, on stderr; nothing stored
```

- **Skip:** **Exclude WhatsApp Chats…** in the menu opens the list
  (`whatsapp-exclude.txt` beside the store). One chat a line, its name or id.
- **Forget what was kept:** each chat's captures carry their own app,
  `net.whatsapp.WhatsApp.chat-<n>`, so one chat is erased alone:
  `pcap forget --source net.whatsapp.WhatsApp.chat-12`. Everything the sensor
  kept: `pcap forget --source sensor:whatsapp`.
- **Pause** holds it with everything else. Adding `whatsapp` to **Edit
  Excluded Apps and Windows…** drops all of it at the gate.

```sh
node sensor.mjs --experimental --once --from me                        # your own messages from the last day, once
node sensor.mjs --experimental --once --history-days 30                # every chat, a month back
node ../../schema/bin/sensor-kit.js -- node "$PWD/sensor.mjs" --experimental --once   # check it
```

Tests: `npm run test:plugins` from the repository root.
