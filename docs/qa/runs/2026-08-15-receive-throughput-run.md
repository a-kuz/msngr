# Receive throughput, 2026-08-15

Why the receiving side fell behind a sender four times slower than itself, where
the time actually went, and what changed.

## Stand

Private: `wrangler dev` on :8853 with its own `--persist-to`, APNs pointed at a
sink that answers 200 and spawns nothing. Receiver is a simulator running the
app (iPhone 17, Debug build); the sender is `ReceiveThroughputBench` driving the
core against the same stand, so the sender is never the limit (150-170
messages/s).

## Where the time went

The engine is not the bottleneck. `swift test --filter ReceiveThroughputBench`
against the stand, receiver on a file database and no interface at all:

| history in the chat | ingest |
|---|---|
| 0 rows | ≥500/s |
| 20 000 rows | 716/s |

The app is. A 30-second `sample` of the receiver while it ingested a burst, at a
history of roughly 10 000 rows:

- database queue, 20 839 running samples: 18 045 (87%) inside ValueObservation
  refetching at commit time — 12 278 of them the chat list asking each chat for
  its newest message, an ordering no index covered; the receive path itself
  (decrypt, message row, cursors) was about 2 400 (12%);
- main thread, 21 421 samples: 19 808 (92%) blocked in a synchronous read of the
  pending key change, taken from the observation callback and waiting on the
  same serial queue the engine writes on.

Both costs are per commit, and the chat-list query walks the whole chat, which is
why the rate decayed with the chat: 62/s at 2 400 rows, 48/s at 5 400, 31/s at
10 000, 23/s at 15 000.

A second profile after those two were fixed moved 95% of the queue into the chat
feed: while the reader is away from the bottom the window floor stays put by
design, so the window grew by a row per arriving message and was refetched whole
on every commit.

## Before and after

Same snapshot restored twice (15 001 rows in the chat), same 6 001 messages
replayed from the server journal, chat screen open, catch-up path:

| | ingest | CPU |
|---|---|---|
| before | 6 001 in ~3.5-4 min, sampled 19-26/s | ~105% |
| after | 6 001 in 3.9 s, ~1 540/s | — |

Repeated at a larger history: 10 000 messages into a chat of 27 003 took 5.1 s
(~2 040/s), steady across the run — the rate no longer falls as the chat grows.
Process CPU for that whole launch, including the migration and the ingest, was
19.1 seconds; the app was idle immediately after.

Nothing was lost on either run: 37 003 rows, seqs 1..37 003 with no duplicates,
`syncedSeq` = `lastSeq`, no deferred envelopes, no unreadable seqs, every text
intact.

## Also seen

At 171 messages/s of live traffic the stand stopped fanning out: the receiver
took 641 frames and then nothing, while APNs deliveries stopped at the same
point, so `/event` was no longer being called. The client was idle with a live
socket and could not know. Restarting `wrangler dev` drained the queue and the
client caught up to the last message on its own. Server side, not reproduced
deliberately, cause unconfirmed.
