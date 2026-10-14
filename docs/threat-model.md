# Threat model

What Presence Capture protects, from whom, and where that protection ends. It consolidates
[ADR 0001](adr/0001-serving-trust-boundary.md) (serving), [ADR 0002](adr/0002-erasable-revocation.md)
(erasure), [ADR 0007](adr/0007-plugins.md) (plugins) and
[ADR 0008](adr/0008-recall-indexes-in-memory.md) (recall in memory), with
[ADR 0003](adr/0003-retention-is-revocation.md) for retention. Where this page and an ADR
disagree, the ADR and the code win. Please report the difference.

Last checked 2026-10-14, against those ADRs (ADR 0008 as amended that day) and the code on
`main` after the R3 merge. The project is pre-alpha (0.x), so details can change.

## Summary

Presence Capture writes the text of your screen, what you're doing, and transcripts of audio
your Mac plays or hears into one SQLite file on that Mac. Content is sealed at rest, each
capture under its own key, and the master key is in your Keychain. AI agents read it only
through `pcap-mcp`, a local, read-only MCP server, under a grant you issue. A grant limits what
an agent can read, every row served goes into a hash-chained log, and everything served is
labeled untrusted. Forget deletes the sealed content and its keys, and a test reads the disk
to check.

**This project is not independently audited.** It has been reviewed by Codex and Claude, and a
conformance suite tests it, including a forensic scan of the store's files. No outside human
has reviewed the design or the code.

The limits that matter most:
- **Captured text is attacker-controlled.** Anyone whose text you view can plant instructions
  in your record. The envelope labels them. It can't make an agent obey the label.
- **There is no boundary between processes that run as you.** One that can start the app's own
  programs can read what an agent can.
- **Erasure reaches this store and later copies.** A backup made before a Forget keeps the
  sealed content and its key.
- **Metadata stays:** when, which app, which URL, what level.
- **An agent keeps what it read.** Nothing here reaches into the agent.

## What's on disk

The store is `~/Library/Application Support/Presence Capture/store.sqlite`, with its `-wal` and
`-shm` files (`PRESENCE_CAPTURE_HOME` moves the folder). Beside it, in plain text, are your
exclusion list, `sensors.json` (commands and pins), and `logs/capture.log` (counts and states,
never captured content).

- **Sealed:** extracted text (screen text, transcripts, activity details such as window
  titles), payload bytes if any are kept, and projection outputs. Each capture has its own
  random data key. Values are AES-256-GCM with the capture's ID in the authenticated data, so
  a sealed value can't be moved to another capture. The master key wraps each data key, and
  the wrapped key sits in the store (ADR 0002 §2).
- **Plain metadata:** capture ID and sequence, time, type, source, source app (bundle ID),
  source URL where the browser reports one, privacy level, extraction method, which capture
  it derives from, and payload size. Also grants, the egress log, revocations and erasure
  receipts. The metadata is the audit trail. Sealing it would make revocation unprovable, not
  more private (ADR 0002 §2).
- **Not kept at all:** pixels and audio ([ADR 0005](adr/0005-text-first-capture.md)).
- **Before sealing,** the app skips excluded windows, then redacts. Redaction is pattern
  matching: private keys, tokens, `password=` pairs, emails, SSNs, card numbers, IPs, phone
  numbers, UUIDs and home-folder paths. It misses what the patterns don't describe. If your
  exclusion list can't be read, nothing is captured.

### The master key

- It's 32 random bytes, made on first launch, kept in your login Keychain and marked not to
  sync. The store never writes it, and refuses to open under any other key.
- The Keychain item trusts the app, `pcap-mcp` and `pcap` by code signature, so they read it
  without a prompt. For any other program, macOS asks you.
- The same key sits in more than one Keychain item: older items are left in place. There is no
  key rotation yet (ADR 0002 §4).
- `--master-key-file` exists for tests and other stores. A key file kept next to the store
  undoes the sealing.

## Trust boundaries

```text
  authors of what you view          never trusted (what it means)
  Presence Capture.app              trusted code: writes, serves no one
  store.sqlite                      trusted provenance, untrusted content
  pcap-mcp  <-- grant, egress log   trusted code: the one way out, read-only
  MCP client (the agent)            never trusted
```

The boundary that matters is the exit from `pcap-mcp` (ADR 0001 §2.3).

### The app

The menu-bar app writes and serves no one. Every five seconds, unless paused, asleep, locked or
another user has the Mac, it records the front app's on-screen windows as text (accessibility
first, then Vision OCR), the active app and window, and on-device transcripts of system audio
(on by default) and the microphone (off until you turn it on). Recognition never falls back to
a network service ([ADR 0004](adr/0004-apple-on-device-models.md)).

Before disk, in order: exclusion, redaction, sealing. An excluded window isn't read, and
activity then records the state alone, not which app. Secure text fields are skipped. The app
is signed with the hardened runtime and has one entitlement, audio input
([`PresenceCapture.entitlements`](../packages/daemon/PresenceCapture.entitlements)). It isn't
App Sandboxed. macOS asks you for Screen Recording, Accessibility and the microphone. The app's
own one network request is Check for Updates…, which you choose, to `api.github.com`. It opens
the release page and installs nothing. When hearing is on, macOS also downloads Apple's speech
model for your language, once, through its own asset service.

### Dictation (experimental)

On macOS 26, if you turn it on, holding a key and speaking types the words where
the cursor is. It's off until you choose it, and asks then for its own
permissions:
- **Input Monitoring**, for the key. The event tap is listen-only and asks for
  modifier changes alone, so it never sees a key typed. But the permission macOS
  grants is broader than that.
- **Accessibility**, to type. The words go in through Accessibility where the
  field takes them. Otherwise they're pasted: your clipboard is saved whole, the
  words are written to it (marked transient) and pasted, and 750 ms later your
  clipboard is put back.

The focused field is checked at key-down, at release, and again just before
typing. If it's a password field, or one whose kind can't be told, nothing is
typed, shown or kept. If it moved, the words are held in a panel instead of
typed. With **Remember What I Dictate** (on by default), what you said is kept
like any transcript: excluded windows, password fields, cancelled dictations
and Pause keep nothing. Its limits are in
[known-limits.md](known-limits.md#dictation).

### `pcap-mcp` and grants

An agent starts `pcap-mcp` over stdio. There is no socket (ADR 0001 §4.4). It serves six
read-only tools (`search`, `recent`, `timeline`, `transcript`, `now`, `session`) and refuses
resources, prompts and logging. Grants are enforced in the store layer, below the tools, so a
handler that forgets to filter still can't over-serve (ADR 0001 §4.1). SQLite limits the
reader's connection to reads plus inserts into the egress log, so a `pcap-mcp` bug can't
change a capture, a key or a grant (ADR 0008 §4).

| A grant limits | Detail |
|----------------|--------|
| Privacy level | `standard`, `sensitive` or `excluded`. `sacred_mode` can't be named: the schema refuses it |
| Types, sources, time | An allowlist of capture types and of sources, and a time window |
| Rows per read | 100 by default |
| Life | Expiry is required (30 days by default). Revoking takes effect on the next call |

- A call with no grant, or an expired or revoked one, gets an explicit denial, not an empty
  result.
- **Connect an Agent…** and `pcap connect` give each agent its own grant: `standard`, every
  type, 30 days. They show the change to the agent's config file, ask first, and copy the file
  aside. Granting `sensitive` or `excluded` takes `--levels` on `pcap grant add` or
  `pcap connect`.
- The macOS app writes every capture at `standard` today. The level doesn't yet separate
  secrets from ordinary text. Exclusion, redaction and the type, source and time limits do that
  work. See ADR 0001 §6.3, below.

**The egress log** gets one record per response: time, client, grant, tool, a fingerprint of
the query (an unkeyed SHA-256, not the text), capture IDs, levels, row and byte counts, and
the previous record's hash. Triggers refuse updates and deletes, no tool can serve it, and a
unique index refuses a fork. `pcap check` re-verifies the chain. `pcap egress` and
**Agents Read…** show each agent's reads by day, as counts. Revoking a grant doesn't redact
past records. `pcap-mcp` also records the rows it loads into its in-memory index, as tool
`index`, so the log lists more rows than an agent was shown. What it was shown is in the
records for the tools it called.

**The envelope.** Every payload leaves wrapped in `presence_capture_untrusted`. Its provenance
(ID, time, app, URL, type, level, extraction) comes from capture metadata, never from the
text, so a page can't forge where it came from. `content` is data, and the server's
`initialize` reply says so. It doesn't filter hostile text. It returns it, labeled
(ADR 0001 §4.3).

### The in-memory index (ADR 0008)

No index of content is written to disk. `pcap-mcp` unseals what its grant admits into SQLite
FTS5 in `:memory:`, with temp storage in memory too.

- It evicts revoked captures by watching the revocation sequence. Separately, every result is
  re-checked against revocations and the grant before it's served, and a revoked capture can't
  be unsealed, because its key is gone. A late eviction can't serve anything.
- Outputs derived from several captures (sessions, digests) are computed in memory, never
  stored. 0.1 stores no embeddings: they can be inverted to approximate their text.
- A revoked or expired grant stops service at once. The process keeps its index in memory
  until it exits.

### Plugins (ADR 0007)

The rule: guarantees hold by construction, not because a plugin promises.

| | Sensors | Projectors | Exporters |
|---|---------|------------|-----------|
| What | An executable that prints observations as JSON lines | A WebAssembly module that computes a derived view from one capture | Anything that sends content out |
| What holds | Never touches the store or key. Same gate as built-in sensors. Captures are tagged `sensor:<name>`, so one sensor can be revoked at once. Dropped, not queued, while capture is held. Runs only if its files match the SHA-256 pins you approved | No imports, so no network, files, clock or randomness. 16 MiB memory cap, a time limit, a fresh instance per capture, output validated, module pinned by hash. Reads through a grant made from its manifest, enveloped and logged. Outputs are sealed under the source capture's key, so Forget erases them | Design only. One that persists is a projector. One that sends gets a single `send` import bound to one destination you approve |
| What doesn't | Runs as you, unsandboxed. It can plant text in your record. Pins catch a swapped file, but they live in `sensors.json` and don't authenticate it | It reads every capture its manifest names | Depends on ADR 0006, which isn't in the repository yet |
| Status | In the reference and the macOS app | Reference host only. The macOS app hosts none | None |

## Forget, revocation and retention

Revocation is the only way content leaves the store (ADR 0003). Forget (menu: last 15 minutes
or last hour; `pcap forget`, up to a day) and retention are both revocations. Forget asks
first and can't be undone.

In one transaction, a revocation records itself and every capture it reaches (audio takes its
transcript with it), prunes projection entries with a receipt each, deletes the sealed text,
sealed payloads and data keys, and writes an erasure receipt with counts. After commit it
truncates the write-ahead log (`wal_checkpoint(TRUNCATE)`), which still holds the frames that
wrote the content. The store runs with `secure_delete = ON`, so deleted cells are zeroed.

- **At once (logical).** Every read path excludes the captures, they can't be unsealed, and
  `pcap-mcp` drops them from memory.
- **On disk (physical).** The store reports `erasedOnDisk` only after the log is truncated and
  the receipt is stamped `completed_at`. A reader holding the log, such as `pcap-mcp` mid-read,
  blocks truncation. The revocation stands, and the menu or `pcap forget` says the erasure is
  pending. The next writer, the app's next tick or `pcap check` finishes it.
- **Later arrivals.** Speech or text stamped inside a forgotten time range is refused when it
  arrives ([SCHEMA.md](spec/SCHEMA.md), R13). Forgetting a source forgets what exists, and
  that source can be captured again. Exclusion is how a source is never captured.
- **Why a key per capture.** An APFS snapshot or an SSD can keep bytes the filesystem was asked
  to remove. The key is a few dozen bytes in one SQLite page that can be overwritten. Without
  it, a surviving ciphertext is noise (ADR 0002 §2).
- **Retention** is the same mechanism with `reason = 'retention'`. The app defaults to 14 days.

How it's tested:
- **The forensic check** (conformance suite, R11) revokes an audio capture and its transcript
  in a real directory, then scans every file: database, WAL, SHM and any blob directory.
  Plaintext must never appear, the revoked keys and sealed bytes must be gone, and what the
  master key can still decrypt must lack the revoked content and include an unrevoked control.
  Six mutant stores, each with one erasure step broken, must each fail it (ADR 0002 §3).
- **The live forget check** ([`scripts/live-forget-check.mjs`](../scripts/live-forget-check.mjs))
  runs on a real Mac while the app captures. It snapshots the sealed bytes of the last 15
  minutes, pins the WAL with its own read transaction, and has you choose Forget. Pinned, it
  checks that the revocation is in force and the erasure is pending. Released, it checks that
  the erasure completes and none of the snapshotted bytes remain in any file under the store's
  folder. It doesn't look at backups, snapshots, swap or memory, and it searches for sealed
  bytes, not for your words.

## Adversaries

| Adversary | What holds | What doesn't |
|-----------|------------|--------------|
| **Someone whose text you view, plus an agent with a grant** (ADR 0001 A1, A2, C1). Spoken words count too: they're transcribed | Content always arrives in the envelope, with provenance the text can't forge. The server has no write, send or run tool, so planted text can't act through it. The agent sees only what its grant admits, up to the row cap, and every read is logged | The envelope labels. It doesn't stop a credulous agent from following planted text with its other tools: writing a file, sending a message, passing on what it read. A server-side fix is "an open research problem" (ADR 0001 §6.2) |
| **A malicious or compromised MCP client** (A3), such as a rogue extension | It's confined to its grant. No grant, or an expired or revoked one, is denied on the next call and logged. It can't write, issue grants, read the egress log or reach `sacred_mode` (ADR 0001 §7, T1 to T12) | It reads everything its grant admits. Many small queries can rebuild far more than intended: the log shows it, nothing prevents it (C2). The grant ID is a name, not a secret. It sits in the agent's config and command line, and whatever starts `pcap-mcp` with it reads under that grant |
| **Another process running as you** (A4) | Little. Its reads through `pcap-mcp` appear in the egress log and in **Agents Read…**. Sealed content needs the master key, and macOS prompts for programs not on the Keychain item's list | No authentication boundary between local processes owned by the same user (ADR 0001 §6.1, [SECURITY.md](../SECURITY.md)). The Keychain trusts `pcap`, so a process that runs it can issue itself a grant, or Forget. It can read plain metadata and the egress log from the file. With write access to the file it can drop the log's triggers and recompute its chain, which is unkeyed (ADR 0001 names a local root user here). It can add a sensor to `sensors.json`. While a dictation is pasted, its words sit on the clipboard for up to 750 ms, where any app can read them. Clipboard managers that honor the transient mark don't keep them |
| **Another macOS user** | The store is in your home folder, and macOS makes `~/Library` private to you by default. The project sets no file permissions of its own. Content is sealed, and the key is in your login Keychain. Capture pauses while another user has the Mac | Admin accounts and root can read the files, metadata included. Whoever has your login password can unlock your Keychain |
| **Someone with a copy of the disk or a backup** (stolen Mac, Time Machine) | Content is ciphertext without the master key. After a Forget the key is gone from the live store, so a surviving copy of the ciphertext (snapshot, SSD remnant, later backup) is noise | Metadata is plain: times, apps, URLs, grants, the egress log. A backup made before a Forget holds the sealed content and its wrapped key, readable with the master key (ADR 0002 §4). The master key is in the login Keychain, which a backup of your home folder normally includes. Your login password and the backup's encryption protect it, not this project. The app doesn't require or check FileVault |
| **A malicious plugin** (ADR 0007) | A sensor can't touch the store or key. Its output passes the gate, is tagged and can be revoked, and it runs only if its files match what you approved. A projector has no network, files, clock or randomness, runs under size and time limits, and its output is validated and sealed under the capture's key | A sensor runs as you, unsandboxed: it can read your files and use the network. Approve only commands you've read. A projector reads whatever its manifest names. The macOS app hosts none, so the Mac app has no projector surface today |
| **A compromised release pipeline** | Releases come only from [`release.yml`](../.github/workflows/release.yml), on a GitHub-hosted runner, from a `v*` tag, in a protected `release` environment that holds the Apple credentials and asks the maintainer to approve each run. They're signed (Developer ID, hardened runtime), notarized and attested. You can verify the attestation (workflow, tag, commit, runner), the checksums and Apple's checks, and run the checks that must fail ([verify.md](verify.md)). The SBOM lists the three programs, and there are no third-party runtime dependencies. Updates are manual | An attestation says where a DMG was built, not that its source is benign. Signing and notarization name the publisher and catch tampering. They aren't a code review. Compromise of the maintainer's GitHub account, the environment approval or the Apple credentials could yield a validly signed bad build. Builds aren't bit-for-bit reproducible in 0.1 ([building.md](building.md)). The commit you verify against comes from the release notes, so check it against the tag in the repository |
| **A network attacker** (A5) | There is no listener. `pcap-mcp` speaks stdio. The app's one request is the update check you choose, over HTTPS, and macOS fetches the speech model through its own service | Out of scope in v1, by construction. An agent's own network access isn't ours to limit |

## Out of scope and known limits

The ADRs state these. They're design limits, not bugs.

**ADR 0001 §6**
- *Local client identity is advisory.* `client_id` is reliable for attribution in the common
  case, and not reliable as an authorization boundary against A3 or A4.
- *The envelope labels the problem; it does not fix it.* "A client that chooses to concatenate
  `content` into a prompt is not prevented from doing so by anything the server can emit."
- *Classification is per event, so bleed is possible.* A `standard` capture that shows
  `sensitive` content carries the weaker level. Fixing it needs content-aware classification.
- *Detection, not prevention, for breadth and tampering.* Large-scale querying (C2) and log
  tampering (C5) are made visible, not impossible.
- *Open (§8).* The egress log grows without bound, is itself sensitive, and has no retention
  contract yet. Making client identity authoritative (by code signature, say) is undecided.

**ADR 0002 §4**
- *Backups taken before a revocation* hold the wrapped key and the ciphertext. Anyone with that
  backup and the master key can still read them. Rotating the master key would close this and
  is future work. Until then, "erased" means erased from this store and every copy made after
  the revocation.
- *Metadata stays.* Capture type, time, source app, source URL where established, privacy
  level and payload size all remain. A URL can be revealing on its own. Revoking a source
  erases content, not the record that the source was used.
- *Process memory.* Content unsealed for a read lives in memory until it is garbage-collected,
  and the reference implementation doesn't scrub it.
- *A reader holding the write-ahead log* blocks its truncation. The revocation still takes
  effect at once, and the erasure finishes when the reader lets go.
- *SSD and filesystem remnants* of SQLite pages are below what `secure_delete` can reach. The
  key per capture covers them, "not a claim about the hardware."

**Dictation** ([known-limits.md](known-limits.md#dictation))
- A move to another field of the same app in the moment after the key goes
  down, or comes up, can go unnoticed. The words are then typed into the field
  you're in at release, never into a password field, which is checked again
  just before typing.
- A paste can arrive after your clipboard is put back, in an app slower than
  750 ms to read it.

**ADR 0007 and ADR 0008**
- Sensors "stay the honest exception." The gate guarantees what a sensor stores, and "nothing
  can guarantee what a native program does on its own."
- `pcap-mcp` holds the unsealed text of everything its grant admits for as long as it runs.
  The swap file is macOS's to protect: it is encrypted by default on Apple silicon.
- A store too large for memory needs another design. Blind indexing is the candidate, with its
  leaks stated.

**Also true, and not stated in an ADR**
- Anything you show on screen and haven't excluded can be captured. Exclusion matches app names
  and window titles, and redaction matches patterns.
- An agent keeps what it read. Erasure is from this store (ADR 0002 §4), not from the agent's
  context, logs or other tools.

## Reporting

Report vulnerabilities privately, through a GitHub security advisory, as
[SECURITY.md](../SECURITY.md) describes. Please don't open a public issue for anything that
could expose captured data. SECURITY.md lists what is in scope. If you think a limit on this
page is worse than it says, that is in scope too.
