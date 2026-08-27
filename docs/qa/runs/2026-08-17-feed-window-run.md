# The feed window after a jump: the same four scenarios, before and after

Run date: 2026-08-17. This run answers the first four tasks of
`2026-08-16-large-chat-perf-run.md`: the feed window that never shrank, the
keystroke that refetched the feed, the observation whose region covered the
whole `chat` table, and the FTS triggers that reindexed a message on any update.

## Stand

Own `wrangler dev` on :8892 with its own `--persist-to` outside the repository
and `APNS_HOST` pointed at a local sink that answers 200 and drops the push. One
own simulator, iPhone 17, iOS 26.5: `perfw-a` (60E73877) as user `2001`. The app
is launched with `MSNGR_SERVER=http://localhost:8892` and `MSNGR_PERF=1`.

The direct chat holds 18 611 messages, seeded through the regular send path;
`lastSeq` is 18 611. The seeding stalled with 1 402 messages that never got a
`seq`, and those rows were deleted before the run, which is where 20 000 became
18 611. Usernames and search queries are digits: on this host the simulator maps
hardware key codes through a Russian layout.

Two builds, both carrying the same `main` (`4ab239e`):

- **before** — `63e8e9f` merged with `main`: the tracing of the earlier run and
  none of the four fixes.
- **after** — `b1aa304`, the same merge with the four fixes on it.

The device database is carried from one build to the other, so both runs work on
the same messages. Before the baseline run the FTS triggers are put back to their
unconditional form and the `v19` migration row is removed, so the baseline
reindexes on every update the way it did before the fix.

## How it was measured

Counters, because they are what holds. `AppDatabase.open` installs a GRDB
profile trace under `MSNGR_PERF=1`: every statement lands in `perf-trace.jsonl`
with the time SQLite spent on it, the screens mark their own work as spans
(`feed.fetch`, `feed.build`, `feed.apply`, `feed.ui.apply`, `bubble.measure`),
and the host stamps the wall clock around each scenario, which is what cuts the
trace into the windows below. Out of that trace this run reads how many rows the
window held, how many times the feed was refetched, how many bubbles were
measured and which statements ran — none of which changes with the machine.

Statement costs are virtual machine steps on a copy of the device database
(`sqlite3 .stats vmstep`), which are load-independent by construction. The FTS
work is measured as what a receipt writes into the search index, because virtual
table work happens inside the FTS module and barely shows up in VM steps.

Frame times are reported at the end and prove nothing on their own: the host
carried five other agents at a load average between 200 and 570 during both runs.
A frame that is slow here is slow everywhere, so the long frames of the baseline
are real; the absence of a long frame afterwards is not evidence, and the device
run is still owed.

## What the four scenarios cost, in counters

| Scenario | Window rows | Feed refetches | Window reads | Bubbles measured |
|----------|------------:|---------------:|-------------:|-----------------:|
| Open the chat | 60 → 62 | 1 → 1 | 1 → 1 | 60 → 62 |
| Scroll up, 10 flicks | 480 → 420 | 7 → 6 | 7 → 12 | 427 → 366 |
| Type 5 characters | 480 → — | 5 → 0 | 5 → 0 | 0 → 0 |
| Send after that | 481 → 63 | 3 → 2 | 3 → 2 | 1 → 1 |
| **Jump to message 500** | **18 175 → 180** | 3 → 2 | 3 → 3 | **18 176 → 180** |
| **Type 5 characters after the jump** | **18 174 → —** | **5 → 0** | **5 → 0** | 0 → 0 |
| **Send after the jump** | **18 176 → 64** | 3 → 2 | 3 → 2 | 1 → 64 |

"Window rows" is the size of the feed window read out of the `feed.apply` marks;
a dash means the feed was not rebuilt at all during the scenario. The three rows
in bold are what the earlier run pointed at.

Three things fall out of the table.

**The jump no longer takes the conversation with it.** The window that used to
hold 18 175 messages holds 180: the target with a page of history below it and
two pages of room above. Every bubble in that window is measured on arrival, so
the same jump measured 18 176 bubbles before and 180 after.

**Typing does not touch the feed.** Five characters produced five writes of the
draft in both runs and five full window refetches in the baseline; after the fix
the window is not read at all. The draft write is still there — the debounce
collapses only keystrokes closer together than half a second, and the host typed
one character every 0.6 s — but the feed no longer listens to it: the chat row
is observed on its own, and the window fetch does not read that table.

**A send from the history comes back to the end of the chat.** In the baseline
the send was applied to the 18 176-row window it was sent from. After the fix the
window is reset to a page first, which is also what makes the sent message
visible: a window standing in the history holds its capacity upwards from its
floor, and in a chat that has piled up that many messages since, a new outgoing
message would not fall into it at all.

## What each statement costs at this size

Virtual machine steps on a copy of the device database, 18 611 messages.

| Statement | Where | VM steps |
|-----------|-------|---------:|
| `COUNT(*)` of everything newer than the target | `anchorWindow`, before | 93 565 |
| Floor a page below the target | `HistoryWindow.floorBelow`, after | 619 |
| Window contents, 18 112 rows | the jump, before | 1 521 434 |
| Window contents, 180 rows | the jump, after | 15 145 |
| Window contents, a page at the end | entering the chat | 5 065 |
| `EXISTS` newer than the window | `HistoryWindow.hasNewer`, after | 20 |

The jump used to read the whole conversation into memory and count it twice: once
to size the window, once to fill it. It now reads a page below the target and one
`EXISTS` to know whether anything is newer, which is what tells the screen to keep
offering the way down.

## What a delivery receipt writes into the search index

A receipt over 5 000 outgoing messages changes `status` and nothing else. Rows in
`messageFts_segments` and their bytes, before and after that one statement:

| Triggers | Segments | Bytes in the index |
|----------|---------:|-------------------:|
| Any update (before) | 108 → 123 | 515 764 → 615 698 |
| Only when the text moves (after) | 108 → 108 | 515 764 → 515 764 |

The receipt used to write 15 new segments and 99 934 bytes into the search index
of a chat whose text had not changed by a character. It now writes nothing.

## Frames

Recorded, and to be read with the load average next to it. The `before` run was
taken at a load average of 571, the `after` run at 226; the same host carried
five other agents throughout.

| Scenario | Longest frame, before | Frames > 250 ms, before | Longest frame, after | Frames > 250 ms, after |
|----------|----------------------:|------------------------:|---------------------:|-----------------------:|
| Open the chat | 132 ms | 0 | 68 ms | 0 |
| Scroll ×10 | 496 ms | 1 | 103 ms | 0 |
| Type 5 characters | 304 ms | 1 | 88 ms | 0 |
| Send | 83 ms | 0 | 2 408 ms | 3 |
| Jump | 1 696 ms | 1 | 738 ms | 1 |
| Type after the jump | 1 374 ms | 3 | 322 ms | 1 |
| Send after the jump | 445 ms | 2 | 82 ms | 0 |
| Back to the bottom | 978 ms | 1 | 1 364 ms | 1 |

The goal the tasks were given — no frame longer than 250 ms after the jump — is
not shown to be met here. Typing after the jump still drew one frame of 322 ms,
the way back down drew one of 1 364 ms, and the first send of the `after` run
drew a 2 408 ms frame while the host was at 571. Whether any of that is the app
is a question for a device: the counters above say the work is gone, the frames
here say the machine was busy.

## What was changed

`FeedWindow` can lower its capacity. A jump anchors the window on its target —
a page below it, three pages of capacity — and holds it there instead of
stretching to the newest message; the anchor is released as soon as the window
turns out to reach the end of the chat anyway. Coming back to the bottom, by the
scroll-down button or by sending, resets the window to a page and refetches on
that size. Since the window no longer reaches the newest message by construction,
the fetch answers whether it does (`HistoryWindow.hasNewer`): read receipts wait
for that answer, and the scroll-down button stays on screen while it is false.

The feed observation no longer reads the chat row. The row is observed on its own,
which is what took the whole `chat` table out of the feed's tracked region: a
draft write, an arriving envelope moving `lastSeq` and a peer's read receipt each
cost a full window refetch before. The draft also settles for half a second before
it is written, and is written at once on send and on leaving the screen.

The FTS triggers carry `WHEN new.text IS NOT old.text` (migration
`v19-ftsOnTextChange`).

Tests: `FeedWindowTests` covers the bounded jump, the anchored window ignoring
"at bottom", the release of the anchor and the return to a page;
`HistoryWindowTests` covers `hasNewer`; `MessageSearchTests` covers that the
index follows the text and not the status.

## What is left

The frame times of all of this on a device. The counters say the jump stopped
reading the conversation and the keystroke stopped reading the feed, and both of
those hold on any machine; what a frame costs after the jump only a phone can
say.

Two things this run walked into and left for their owners: the chat header
publishes no children to accessibility, so its back button cannot be found in the
tree and a tap where it is drawn does not register (only the screen's own edge
swipe works), and `E2EE.deviceMap` caches nothing, so every send makes its own
`GET /api/devices` — 18 611 of them while this chat was being seeded.
