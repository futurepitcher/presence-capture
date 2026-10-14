# Recall eval

How well, and how fast, an MCP server recalls ([ADR 0008](../docs/adr/0008-recall-indexes-in-memory.md)).
CI runs it against `pcap-mcp` on every pull request, and fails below the
release plan's targets: **recall@5 of at least 0.80, and a search p95 under
300 ms**.

```sh
npm run eval                                              # the reference, three days
npm run eval -- --days 30                                 # with 30 days of filler: about 18,000 captures
npm run eval -- --days 30 --server /path/to/pcap-mcp      # any MCP server
npm run eval -- --days 30 --embed <command> --server ...  # a candidate model for search by meaning
```

## The fixture

`fixtures/three-days.json` holds three hand-written days: a day of code, a
day of calls, and a day of reading and messaging. Every capture names its id,
and every question the ids that answer it. Half the questions use the
captures' own words (`keyword`); half ask in other words (`paraphrase`), which
only search by meaning can answer. It's synthetic: every person, company and
number is made up.

`filler.js` adds days of ordinary text around them, deterministic from a fixed
seed: screen text, activity and speech in common words, competing with the
answers the way a real day's text does, and never answering a question itself.

## What it reports

- recall@1 and recall@5, and MRR over the first ten results, for all
  questions and for each kind;
- p50 and p95 latency for `search`, `recent`, `timeline` and `now`;
- the cold start: the first call, which builds the server's memory;
- the questions missed in the top five.

`--json <file>` writes all of it, with every question's top five.

## Where it stands

[`docs/benchmarks.md`](../docs/benchmarks.md) has the current numbers.
Keyword search answers every keyword question and 60% of paraphrased ones.
Search by meaning with Apple's on-device embeddings was measured, and made
things worse, so 0.1 doesn't use it (ADR 0008, amended).
