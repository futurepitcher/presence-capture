# Benchmarks

Numbers anyone can reproduce, with the commands that produce them.

## Recall (the eval)

[`eval/`](https://github.com/futurepitcher/presence-capture/blob/main/eval/README.md), run on 2026-10-14 against `pcap-mcp` built in
release, on an Apple Silicon Mac:

```sh
swift build -c release --package-path packages/daemon --product pcap-mcp
npm run eval -- --days 30 --server "$(swift build -c release --package-path packages/daemon --show-bin-path)/pcap-mcp"
```

| | Recall@1 | Recall@5 | MRR |
|---|---|---|---|
| All 50 questions | 68% | **80%** | 0.73 |
| 25 keyword questions | 96% | 100% | 0.98 |
| 25 paraphrased questions | 40% | 60% | 0.49 |

Each tool is timed twice: on a quiet store, and again while
[`eval/writer.js`](https://github.com/futurepitcher/presence-capture/blob/main/eval/writer.js) appends twelve captures a second beside
the server, with every call a quarter second after the last, so each one has
a new batch to index and can meet a write. (The daemon samples every five
seconds.) The gate is on the second.

| Tool | p50, quiet | p95, quiet | p50, writing | p95, writing |
|---|---|---|---|---|
| `search` | 2 ms | 7 ms | 13 ms | **20 ms** |
| `recent` | 3 ms | 3 ms | 16 ms | 21 ms |
| `timeline` | 3 ms | 3 ms | 15 ms | 19 ms |
| `now` | 12 ms | 13 ms | 30 ms | 33 ms |

- **The store:** 18,036 captures over 30 days.
- **Cold start:** 1.3 s for the first call, which reads everything the grant admits into memory.
- **While writing:** 354 captures appended during the timed calls.
- **Targets:** recall@5 at least 0.80 and search p95 under 300 ms while writing, both met. Recall is at the target exactly, with no room to spare.
- **Answers:** a question counts as answered only by a capture that answers it on its own; one that only mentions the subject doesn't count.

Search by meaning was measured the same way, with Apple's on-device sentence
embedding and the same 30 days:

| Ranking | Recall@5 |
|---|---|
| Keyword (BM25) alone | 40/50 |
| Embeddings alone | 15/50, and 1 of the 25 paraphrased questions |
| The two fused (reciprocal rank) | 37/50 |

So 0.1 searches by keyword
([ADR 0008, amended](adr/0008-recall-indexes-in-memory.md)). A stronger model
has to beat 40/50 on this eval before it ships.

## The live forget check

Forget, on a real Mac with the app capturing, checked the way someone holding
a copy of the store would check it: by looking for the exact sealed bytes of
what was forgotten in every file under the store's folder.
[`scripts/live-forget-check.mjs`](https://github.com/futurepitcher/presence-capture/blob/main/scripts/live-forget-check.mjs) walks you
through it, with the app running and capturing for 20 minutes or more, and Hear
the Microphone on:

```sh
node scripts/live-forget-check.mjs \
  --store "$HOME/Library/Application Support/Presence Capture/store.sqlite" \
  --mcp "/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp"
```

1. It gives itself a one-day grant, notes a control capture from before the
   window, and asks you to put two words on screen and say them aloud. It
   waits until both are captured and readable through `pcap-mcp`: from the
   screen, and heard by the microphone.
2. It snapshots, capture by capture, the sealed bytes of everything from the
   last 20 minutes (wider than the 15 Forget will take): wrapped keys, sealed
   text and payloads, projection outputs. These are raw bytes, so no key is
   needed.
3. It holds a read transaction of its own on the store, so the write-ahead log
   can't be checkpointed. Then it asks you to choose Forget the Last 15
   Minutes… in the menu.
4. While it holds that, it checks:
   - the words can no longer be found;
   - the revocation names exactly, no more and no less, every capture stamped
     in its range and what was derived from them, less what earlier
     revocations had taken, worked out from the store's metadata;
   - the erasure receipt and per-projection receipts exist, with the erasure
     pending.
5. It lets go, and within 10 seconds (two of the app's 5-second ticks) checks:
   - the erasure completed;
   - none of the snapshotted bytes of the captures it revoked is left in any
     file under the store's folder;
   - nothing stamped inside the window is stored unrevoked;
   - the control capture is still readable.

It exits 0 on PASS, 1 on any failed check, 2 if it can't run, and 3 if it's
incomplete: the words were seen but never heard. It revokes its own grant
however it ends, Ctrl-C included, and checks that it did. The artifact scan is
the conformance suite's
([`inspect.js`](https://github.com/futurepitcher/presence-capture/blob/main/packages/schema/conformance/store/inspect.js)).

## Still to measure

The release plan's live checks are run on the maintainer's Mac and recorded
here before 0.1.0:
- the live forget check (above);
- the seven-day soak (CPU, memory, store growth);
- the screenpipe parity trial;
- dictation latency.
