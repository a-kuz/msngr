# What a 20 000-message chat costs on the wire and in the objects

Date: 2026-08-16. Stand: own `wrangler dev` on :8893 with `--persist-to
server/.wrangler-perfnet`, migrations applied there; APNs sink on :9893. No
simulator and no app build took part: the traffic was produced by a Node client
that speaks the protocol (REST + `/ws` frames) directly, so every byte and every
frame below is the wire format the app uses.

Data: one direct chat with 20 001 messages between two registered users, both
carrying a push token, and a second chat of 100 messages next to it, so a
per-chat cost can be told apart from a per-connection one.

Server cost is read from `PERF` log lines: with `PERF_LOG` set, each object
invocation logs its storage operations, the records a `list` returned, D1
statements, subrequests to other objects and the bytes written to sockets
(`server/src/perf.ts`). Invocations of one object interleave across awaits, so a
burst is read off the cumulative totals; single-shot scenarios are read off the
per-invocation numbers.

Timings on this host are worth much less than the counts. The machine ran a
double-digit number of other workerd processes throughout, load average stayed
between 300 and 550, and single requests occasionally stalled for seconds (one
history page took 160 s in one sample). Counts, sizes and record numbers repeat
exactly; medians move by a factor of five between runs of the same code.

## Entering a chat

Opening a chat screen sends nothing: the feed comes from the local database, and
the only frame that leaves is the read mark.

| | frames / bytes out | in | object invocations | keys written | subrequests |
|---|---|---|---|---|---|
| open chat, everything local | 1 × 100 B (`read`) | none | 4 | 5 | 2 |

Connecting the app is where the size of the chat used to show. The app start
measured here is: `GET /api/chats`, `/api/prekeys/count`, `/api/blocked`, the
socket, and a `sync` with both chats' cursors at the head — nothing to catch up
on.

| | records the objects listed | object time | wall | `syncDone` after |
|---|---|---|---|---|
| before | 20 566 | 6 765 ms | 4 412 ms | 3 330 ms |
| after | 10 | 23 ms | 508 ms | 7 ms |

The traffic itself is small either way: 160 B out, 6 frames / 1 569 B back
(`hello` 70 B, two `syncState` 232 B, two `chat` 1 238 B, `syncDone` 29 B).

Repeated over 12 connects, reading the per-chat cost off the log:

| | `/events` median | max | records listed | whole `sync` round trip |
|---|---|---|---|---|
| before, 20 000-message chat | 178 ms | 3 171 ms | 20 706 | 193 ms |
| after, 20 000-message chat | 0 ms | 1 ms | 0 | 15 ms |
| 100-message chat, before | 0 ms | 4 ms | 100 | |

`/events` is called once per chat on every connect, so the scan was paid per
chat and grew with the journal.

## Scrolling the feed

Scrolling costs nothing on the wire while local rows last: the window floor
moves 60 rows at a time out of the database. The server is asked only for an
open seq gap — a range this device never decrypted — and one request covers one
server page.

| | REST calls | bytes down | records listed | object invocations |
|---|---|---|---|---|
| one page (128) before | 1 | 69 961 | 128 | 2 |
| one page (128) after | 1 | 69 961 | 128 | 1 |

Median page time on a quiet minute after the fix: 10.8 ms over 12 pages. Between
runs the median moved between 8 and 60 ms in both code states, which is host
noise, not a difference: the honest claim for this fix is one object invocation
and two storage reads less per page, not milliseconds.

44 % of a page is thrown away by the reader. Of 128 records in a page of this
chat, 56 (30 795 B of 70 387 B) are the reader's own messages, which
`fillHistoryGap` skips as `own_echo` — they are encrypted for the peer and carry
nothing this device can use.

## Sending a message

| | out | back to the sender | to the peer | invocations | gets | keys | D1 | subreq | push |
|---|---|---|---|---|---|---|---|---|---|---|
| peer online | 498 B | `sent` 191 B + `msg` 606 B | 606 B | 8 | 16 | 10 | 1 | 4 | 1 × 828 B |
| peer offline | 499 B | `sent` 192 B + `msg` 606 B | — | 10 | 18 | 10 | 1 | 4 | 1 × 828 B |

The sending device gets its own message back as a full `msg` frame on top of the
ack: 606 B against 191 B, three times the ack, carrying an envelope it already
has. The frame is meant for the sender's *other* devices; it is delivered per
user, not per device, so a single-device sender pays for it too.

Fifty sends in a row, no pauses:

| | value |
|---|---|
| out | 50 frames / 24 890 B |
| back to the sender | 100 frames / 39 818 B, of which 30 289 B is its own echo |
| to the peer | 50 frames / 30 289 B |
| objects | 704 gets, 500 keys written, 50 D1, 200 subrequests |
| pushes | 50 / 41 437 B |
| fanout queue at the last ack | 49 jobs, oldest waiting 3.0 s |
| drained | 1.05 s after the last ack |

Per message that is 14 gets, 10 written keys, one D1 statement and four
subrequests, one of them the `/unread-count` the badge recount asks for. The
queue depth is the intended shape — `/send` answers as soon as the message owns
a seq — but it means the ack is up to a second ahead of delivery under a burst.
The second run of the same burst drained inline (0 jobs at the last ack) because
the host was slower than the queue; the depth is a property of the send rate, not
of the fixes in this run.

## Jumping to an old message

The pinned bar only exists while the pinned message is inside the current feed
snapshot (`ChatViewModel.pinnedMessage`), so a message pinned near the start of a
20 000-message chat shows no bar to tap and produces no traffic at all. The deep
jump that does exist — a reply quote, search, the gallery — goes through
`ensureLoaded`, which anchors the window if the message is already stored and
otherwise pages back at most 12 times (`maxPages: 12`) before giving up with a
haptic.

| | REST calls | bytes down | records listed | invocations |
|---|---|---|---|---|
| the full 12-page walk | 12 | 845 KB | 1 536 | 12 (24 before) |

1 536 messages back is 8 % of this journal, so a jump to anything older than that
cannot succeed from the network side no matter how long the reader waits.

Catch-up over the socket, having missed 200 messages, for comparison:

| | frames in | bytes in | portions | records listed | invocations |
|---|---|---|---|---|---|
| before | 207 | 122 770 | 2 | 20 914 | 13 |
| after | 207 | 122 777 | 2 | 206 | 13 |

A portion is 128 messages and ends with `syncDone{more}`; the client asks again
from the cursor it was given. A chat absent from the cursor map of `sync` is
replayed from seq 0 by the same mechanism, which for this chat is 157 portions
of about 78 KB — read from the code (`SYNC_PAGE`, `serveCatchup`), not measured.

## Fixed in this run

**`/events` scanned the whole journal to answer with an empty list.** The chat
tail a client asks for on every connect (tombstones, read and delivered marks,
roster) walked every `msg:` record to find deleted ones. Messages removed for
everyone now write a `tomb:` record of their own and `/events` reads those:
20 706 records listed became 0, and the `sync` round trip on this chat went from
a 193 ms median to 15 ms. Old tombstones written before this change are no longer
reported, which is the usual no-compatibility trade in this repository.

**A page of history cost two object invocations.** `GET /api/chats/:id/history`
asked the object for `/state` to check membership and then asked it again for the
page, although `/history` refuses a non-member itself on the same read that
serves the page. The pre-check is gone: one invocation and two storage reads less
per page, i.e. 12 invocations less on the 12-page walk above.

`node test/smoke.mjs` passes against the changed server (`BASE_URL` :8893,
`PUSH_PORT` 9893), including the delete-for-all and fresh-sync tombstone checks
that cover the new index. One earlier smoke run failed two fanout-timing checks
(`fanout is queued, not inline`, `a queued job reports its wait`) while the host
was thrashing; both passed afterwards on the unchanged and on the changed code.

## Found and left alone

**The own echo to the sending device.** Suppressing it would save 606 B per send
and 30 KB per fifty, but the smoke asserts it in two places (`alice gets own
echo`, `block: own echo still delivered`) with single-device senders, so it is a
protocol decision rather than a safe in-place fix. Dropping it needs the delivery
to be per device rather than per user, and the two assertions rewritten.

**A history page carries what the reader will discard.** 44 % of a page in this
chat is the reader's own messages. The client cannot know in advance which seqs
are its own, so the filter belongs on the server — and the answer would still
have to name the skipped seqs, because `fillHistoryGap` closes the gap by seq.

**`/delete` for everyone still scans the journal** to find messages by msgId
(20 706 records here). Left as it is: deletes are rare and an index would cost a
key per send.

## Not covered

No app, no simulator, no device took part: the host's disk sat at 100 % for most
of the run and an iOS build could not be kept on it. Everything above is the
server and the wire; the client-side half of the same four scenarios (database,
feed, decryption) is measured separately on `run-perfdb`.

The measurement code stays in the tree behind `PERF_LOG` (`server/src/perf.ts`
and the hooks in the two objects and in `index.ts`); with the variable unset no
wrapper is installed and no line is logged. The Node client that drove the
scenarios is not committed — it lives in the run's scratchpad.
