# whatsapp (experimental)

A [sensor plugin](../../../docs/adr/0007-plugins.md) that notes the text
messages of **one** WhatsApp chat, read **read-only** from WhatsApp Desktop's
own database on this Mac. The plan, the consent model and what's unverified
are in [docs/sources/whatsapp.md](../../../docs/sources/whatsapp.md). Read it
before running this.

> **Experimental. Don't connect an agent while it runs.** Its captures are
> `standard`, so any agent with a default grant can read your chats, and with
> `--from both`, other people's words. Tested only against a synthetic
> database. Its command must include `--experimental`, or it won't start.

- One chat per sensor, so each chat is approved, held and revoked on its own.
- Your own messages only, unless that chat's entry says `--from both`.
- History only when that chat's entry asks: `--history-days <n>` (up to 365),
  and kept no longer than the store's retention.
- Text only. No media, contact names or numbers.
- No network, no writes, no copy of the database. It stops if the database
  isn't the shape it knows.

```sh
node sensor.mjs --list-chats                                          # chat ids and counts, on stderr; nothing stored
node sensor.mjs --experimental --once --chat 15555550100@s.whatsapp.net --label Alex   # the last day of your messages in that chat
node sensor.mjs --experimental --once --chat <id> --label <name> --from both --history-days 14   # both sides, two weeks back
node ../../schema/bin/sensor-kit.js -- node "$PWD/sensor.mjs" --experimental --once --chat <id> --label <name>   # check it
```

Reading the database needs permission (Full Disk Access, or macOS's prompt to
read another app's data). Which one is still to be checked on a real Mac.

In `~/Library/Application Support/Presence Capture/sensors.json`, one entry
per chat, each with its own name:

```json
[{ "name": "whatsapp-alex", "command": ["/opt/homebrew/bin/node", "/path/to/sensor.mjs",
   "--experimental", "--name", "whatsapp-alex", "--chat", "15555550100@s.whatsapp.net", "--label", "Alex",
   "--from", "both", "--history-days", "14"] }]
```

Each chat is its own source (`sensor:whatsapp-alex`), so the store can revoke
one chat and erase it. The app and `pcap forget` can't yet: they forget by
time. A per-source forget is planned before this leaves experimental.

Tests: `npm run test:plugins` from the repository root.
