# Quickstart

Presence Capture is a menu-bar app. It remembers the text on your screen, the
words it hears and the app you're in, keeps them sealed on your Mac, and lets
the agents you choose read them. This page takes you from download to asking
an agent a question.

## What you need

- A Mac with Apple silicon, running macOS 14 or later. On an Intel Mac, build
  from source ([building.md](building.md)).
- macOS 26 for hearing (the microphone and what the Mac plays). On macOS 14 or
  15 the app reads the screen and notes your activity, but doesn't listen.
- An agent that speaks MCP. Connect supports Claude Code, Claude Desktop and
  Cursor.

## Install

**From a DMG.** Download `Presence-Capture-<version>.dmg` from
[GitHub Releases](https://github.com/futurepitcher/presence-capture/releases),
open it, and drag Presence Capture to Applications.

**With Homebrew.** The cask is in the `futurepitcher/homebrew-tap` tap. Its
source is [`presence-capture.rb`](https://github.com/futurepitcher/presence-capture/blob/main/packaging/homebrew/Casks/presence-capture.rb).

```sh
brew install --cask futurepitcher/tap/presence-capture
```

Homebrew checks the DMG against the SHA-256 in the cask, and puts the `pcap`
command on your `PATH`.

**Check the download first.** Releases are signed, notarized and attested.
[verify.md](verify.md) shows how to check the attestation, the checksums and
Apple's checks before you open the DMG.

## First launch

Open Presence Capture. It has no Dock icon. It puts an icon in the menu bar, and
the first time, a window called **Welcome to Presence Capture**. The app asks for
nothing until you press a button in that window. Each step says what it's for.

### 1. Screen Recording (required)

Press **Allow Screen Recording…**. The app reads the text on your screen with
Apple's Vision, on this Mac, and on macOS 26 hears what the Mac plays. No images
are kept. macOS shows its prompt, and the button opens System Settings → Privacy
& Security → Screen Recording, where you switch Presence Capture on. The menu
says "Needs Screen Recording" until you do.

### 2. Microphone (optional)

Press **Allow and Hear the Microphone…**. The app turns what the microphone hears
into words, on this Mac. No audio is kept. It stays off until you allow it here,
and **Hear the Microphone** in the menu turns it off again. It hears everyone
near you, not only you, and recording others is governed by law where you are.
Telling them is yours to do. On macOS 14 and 15 this step reads "Hearing needs
macOS 26" and has no button.

### 3. Accessibility (optional)

Press **Allow Accessibility…**. The app then reads the address of the page in
front, and the text of the window in front, more exactly than it can from pixels.
A password field is never read.

### 4. Dictation (optional, experimental)

On macOS 26, press **Turn On Dictation…**. Then hold a key and speak, in any
app: what you say is typed where the cursor is, transcribed on this Mac. It asks
for the microphone, Input Monitoring (it watches the modifier keys alone, so
it never sees what you type) and Accessibility (to type).

- **The key:** Fn (Globe) by default, or Right Option or Right Command. If macOS
  does something of its own with the Globe key, the step says so and offers the
  others.
- **Remember what I dictate** is on by default: what you say is kept like any
  other capture, and forgotten the same way. Never from excluded apps or
  password fields.
- Nothing is typed into a password field. If you move to another field before
  it's typed, the words are held in a small panel for you to copy.

It's experimental in 0.1: see its [known limits](known-limits.md#dictation).
**Dictation (Experimental)** in the menu turns it off, changes the key, and
turns remembering and Tidy What I Say on or off.

### 5. Connect an agent

Press the button for your agent: **Claude Code**, **Claude Desktop** or
**Cursor**. The app shows the change it will make to the agent's settings, and
asks. See [connect.md](connect.md) for what it does and how to undo it.

Press **Done**. Closing the window, by Done or otherwise, means it isn't shown at
launch again. To see it again, choose **Set Up Presence Capture…** in the menu.

## What it captures

Every 5 seconds, unless it's paused, the screens are asleep, the Mac is locked,
or another user has it:

| What | Kept as |
|------|---------|
| The text of each on-screen window of the front app | `screen_text` |
| Words spoken to the microphone, and words the Mac plays (macOS 26) | `audio_transcript` |
| The app and window in front, and whether you're active, idle or locked | `activity` |

It keeps text, never screenshots or audio. Before anything is written, apps and
windows you've excluded are skipped, secrets and personal identifiers are
redacted from the text, and the text is sealed under a key of its own. The
system's own screens (the lock screen, password prompts, notifications) and
Presence Capture's own windows are never read. The record of each capture (its
time, app and the page's URL) isn't sealed, and isn't redacted.

Exclusions cover what's read from the screen, activity and dictation. They don't
reach ambient audio: a call in an excluded app is still heard. Pause, or turn
off **Hear the Microphone** and **Hear System Audio**, to keep it out
([known limits](known-limits.md#capture)).

- **Where it lives:** `~/Library/Application Support/Presence Capture/`
  (`store.sqlite`, and `logs/` with counts only). Set `PRESENCE_CAPTURE_HOME` to
  move it. The key is in your Keychain, on this Mac only.
- **How long:** 14 days. Change it under **Keep Captures For**, from 1 day to 1
  year. A shorter period erases the older captures at once, so the app asks first.
- **What it skips:** **Edit Excluded Apps and Windows…** opens your list, one
  line each. A line matches an app's name or a window's title, in any case.
  Saved changes apply within a few seconds.
- **What leaves the Mac:** nothing you captured. **Check for Updates…** is the
  one request the app makes, and only when you choose it. When hearing is on,
  macOS downloads Apple's speech model for your language once, through its own
  service.

## Pause and Forget

- **Pause** in the menu stops capturing and hearing. It becomes **Resume**. The
  top line of the menu says what the app is doing: "Capturing", "Paused",
  "Waiting (locked)", and so on.
- **Forget the Last 15 Minutes…** and **Forget the Last Hour…** erase that stretch
  from disk, with everything derived from it. The app asks first, because it
  can't be undone. From a terminal, `pcap forget 15m` does the same
  ([connect.md](connect.md) says where `pcap` is).

## Ask your agent something

Start a new session in your agent. Claude Desktop needs a full quit and reopen
first. You don't call tools yourself. The agent picks one
([tools.md](tools.md)). Try:

- "What am I working on right now?" The agent calls `now`.
- "Find where I saw the word invoice today." The agent calls `search`.
- "What did I say in the last hour?" The agent calls `transcript`, which needs
  macOS 26 and the microphone turned on.

What the agent reads is data from your screen, not instructions. Text on a page
can try to give the agent orders, and a careful agent ignores them. To see what
an agent has read, choose **Agents Read…** in the menu. It shows counts, never
content.

## Update and remove

- **Check for Updates…** asks GitHub for the latest release and offers its page
  if it's newer.
- To remove the app, quit it and drag it to the Trash, or run
  `brew uninstall --cask presence-capture`. Removing the app doesn't delete your
  captures. They stay in the folder above until you delete it, or Forget them.
  Withdraw agents' grants first, in **Agents Read…**.
