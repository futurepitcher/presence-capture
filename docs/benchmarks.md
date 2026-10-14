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

## Still to measure

The release plan's live checks are run on the maintainer's Mac and recorded
here before 0.1.0:
- the live forget check;
- the seven-day soak (CPU, memory, store growth);
- the screenpipe parity trial;
- dictation latency.
