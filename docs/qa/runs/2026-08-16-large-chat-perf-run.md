# Where a 20 000-message chat spends its time on the device

Run date: 2026-08-16. The question was what the local database and the feed
actually do when the reader scrolls, sends a message, opens the chat and jumps
to a message far back in the history, and why sending in a large chat draws a
few long frames instead of an animation. The network half of the same size is a
separate run: `2026-08-16-large-chat-network-run.md`.

## Stand

Own `wrangler dev` on :8891 with its own `--persist-to` outside the repository,
`APNS_HOST` pointed at an unused port. Two own simulators, iPhone 17, iOS 26.5,
deleted after the run: `perfdb-a` (1E789E1F) as user `1001`, `perfdb-b`
(876F731F) as `1002`. Both apps launched with `MSNGR_SERVER=http://localhost:8891`.
Build from the working tree.

The direct chat holds 20 059 messages at the start of the run, all seeded
through the DEBUG buttons over the regular send path; `lastSeq` is 20 071 at the
end. Usernames and search queries are digits: on this host the simulator maps
hardware key codes through a Russian layout, so typed Latin arrives as Cyrillic.

An earlier attempt ran while the host carried three other agents with their own
simulators and the gate, at a load average of up to 550 and a full disk. Every
timing below was taken again afterwards, at a load average of about 12; nothing
from the loaded period is reported.

## How it was measured

`AppDatabase.open` installs a GRDB profile trace when the process is launched
with `MSNGR_PERF=1`: every statement is written to `perf-trace.jsonl` with the
time SQLite spent on it, and the first run of each distinct statement carries
the stack that issued it. The screens mark their own work as spans — the fetch
of the window (`feed.fetch`), the build of the feed items (`feed.build`), the
model update (`feed.apply`), the collection view update (`feed.ui.apply`), one
bubble measurement (`bubble.measure`), the chat list fetch (`chatlist.fetch`) —
and `MessagesViewController` runs a display link while the feed is on screen, so
every drawn frame is recorded with the gap since the previous one. The host
stamps the wall clock around each scenario, which is what cuts the trace into
the windows below.

Two things the numbers do not carry. SQLite durations on the simulator are
quantized to a millisecond, so a sum over many statements is meaningful while a
single sub-millisecond statement is not. And the stack is captured on a
statement's first run in the process, so it attributes a distinctive statement
correctly and says nothing useful about `BEGIN`/`COMMIT`, whose text is shared
by every writer.

Work that does not depend on host load was measured separately, in SQLite
virtual machine steps, on a copy of the device database (`.stats on`).

## The four scenarios

Window rows is how many messages the feed window held during the scenario, read
out of the `feed.apply` marks.

| Scenario | Window rows | Feed refetches | SQL in them | Longest frame | Frames > 250 ms |
|----------|------------:|---------------:|------------:|--------------:|----------------:|
| Open the chat from the list | 60 | 7 | 104 ms | 48 ms | 0 |
| Scroll up, 10 flicks | 60 → 900 | 24 | 175 ms | 84 ms | 0 |
| Type 5 characters, then send | 900 | 14 | 117 ms | 89 ms | 0 |
| Jump to message 500 of 20 000 | 60 → 19 620 | 22 | 4 967 ms | 325 ms | 8 |
| Type 5 characters after that jump | 19 620 | 7 | 1 897 ms | 1 127 ms | 4 |
| Send after that jump | 19 620 | 7 | 1 750 ms | 846 ms | 5 |

The same six windows by where the time goes on the main thread:

| Scenario | feed.fetch | feed.build | feed.apply | feed.ui.apply | bubble.measure |
|----------|-----------:|-----------:|-----------:|--------------:|---------------:|
| Open the chat | 104 ms | 2 ms | 3 ms | 44 ms | 60 |
| Scroll ×10 | 175 ms | 72 ms | 77 ms | 191 ms | 854 |
| Type + send | 117 ms | 71 ms | 75 ms | 38 ms | 0 |
| Jump | 4 967 ms | 2 020 ms | 2 135 ms | 2 724 ms | 19 621 |
| Type after the jump | 1 897 ms | 1 193 ms | 1 259 ms | 466 ms | 0 |
| Send after the jump | 1 750 ms | 910 ms | 954 ms | 468 ms | 0 |

### Opening the chat is not the problem

Seven feed fetches, 104 ms of SQL between them, one frame over 33 ms. The window
is the newest 60 messages and the size of the chat does not enter into it: the
floor is one index range (`SELECT MIN(seq) FROM (… ORDER BY seq DESC LIMIT 60)`,
618 virtual machine steps at 20 061 rows) and the window itself is a range on
`message_on_chat_feedOrder`. Resident memory goes from 110 to 212 MB, which is
the collection view and the decoded window, not the chat.

### Scrolling pays per page, and the page is cheap

Ten flicks pull 14 pages through `HistoryWindow.floorBelow`, the window grows
from 60 to 900 rows, and the whole scenario spends 175 ms in the database. Seven
frames pass 33 ms, none passes 100 ms. The cost per page does not depend on the
size of the chat either.

The one thing that does grow is the window, and it grows in the same units the
refetch later pays in: at 900 rows one refetch already costs about 8 ms of SQL
and 5 ms of rebuild, against 1 ms at 60 rows.

### Sending: the feed is refetched once per keystroke

Typing five characters produced exactly five `UPDATE chat SET draft = ?`
(`ChatViewModel.saveDraft`, called from `InputBar` on every change) and seven
full refetches of the feed window. The feed observation reads the chat row
(`Chat.fetchOne`) inside the same fetch as the window, so its tracked region
covers the whole `chat` table: a draft write refires the window fetch, the feed
build, the diff and the collection view update, with nothing on screen changed.

The rest of a send is bounded work: the insert of the row, the outbox insert and
delete, the ack update, and four more chat-row writes (`lastActivityAt`,
`lastSeq`/`syncedSeq`, the badge) — each of which refires the window fetch
again. One send at the bottom of the chat costs 14 refetches; at a 900-row
window that is 117 ms of SQL and no dropped frame, and at a 19 620-row window
the same 14 refetches are what the reader sees as a stutter.

### The jump is what turns the feed into the whole chat

Tapping a search hit on `Test message 500 of 20000` reaches the message quickly:
`jump.begin` → `jump.loaded` is 585 ms, because `anchorWindow` does not page
down to it — it sets the window floor to the target seq and stretches the
capacity to `COUNT(*)` of everything newer (100 816 virtual machine steps at this
size). What it leaves behind is a feed window of 19 620 messages, and that
window is re-read, re-decoded, rebuilt and re-diffed on every write that touches
the chat row or the message table. In the 40 seconds the scenario was watched,
that happened 22 times: 4 967 ms of SQL, 2 020 ms of feed building, 2 724 ms of
collection view updates, 19 621 bubble measurements, eight frames over 250 ms.

The capacity never shrinks. `FeedWindow.anchor` takes `max(capacity, count)` and
nothing lowers it again: after the jump the reader can scroll back to the bottom
and the window still holds the whole conversation. That is the state the owner's
"three frames instead of an animation" is measured in — typing five characters
draws a 1 127 ms frame, and the send after it draws an 846 ms one, with five
frames over 250 ms around it.

Only leaving the chat clears it: the next entry builds a fresh `ChatViewModel`
with a 60-message capacity, which is why the same send measured 18.6 ms of fetch
and a 34 ms worst frame right after a re-entry.

### The pinned message: there is nothing to jump to

Pinning `Test message 500 of 20000` and returning to the chat leaves the chat
with `pinnedMsgId` set (pinned seq 501 against `lastSeq` 20 071) and no pinned
bar on screen. The bar is drawn from `model.pinnedMessage`, and that is picked
out of the window (`snapshot.msgs.first { $0.msgId == pinId }`, ChatViewModel),
so a pin older than the window does not exist for the screen. The scenario "jump
to an old pinned message" is unreachable from the interface as it stands; the
expensive path measured above is the search jump, and the pinned bar's own tap
calls `scrollTo` without `ensureLoaded`, so it would do nothing for a pin outside
the window even if the bar were drawn.

Pinning also does not apply locally: the POST returns 200 and `chat.pinnedMsgId`
stays empty until the next chat-state sync (here, an app restart).

## What each statement costs at this size

Virtual machine steps on a copy of the device database, 20 061 messages. Steps
are load-independent, which is what makes them comparable between the two
columns.

| Statement | Where | VM steps |
|-----------|-------|---------:|
| Window floor for 60 rows | `HistoryWindow.newestFloor` | 618 |
| Window contents, uncapped | `HistoryWindow.messages` (19 570 rows) | 547 719 |
| `EXISTS` older than the floor | `HistoryWindow.hasOlder` | 20 |
| Exhausted gaps in the window | `HistoryWindow.exhaustedGapSeqs` | 11 |
| Last message of a chat | chat list observation | 40 |
| Seq of the jump target | `ChatViewModel.anchorWindow` | 28 |
| `COUNT(*)` newer than the target | `ChatViewModel.anchorWindow` | 100 816 |
| Seqs known to the message table | `HistoryWindow.openGaps` | 117 374 |

Writes, each measured as the last statement on a throwaway copy:

| Statement | Where | VM steps | Fullscan steps |
|-----------|-------|---------:|---------------:|
| Ack: `UPDATE message … WHERE clientMsgId = ?` | `SyncEngine` ack path | 60 363 | 20 060 |
| the same, with an index on `message(clientMsgId)` | after the fix below | 182 | 0 |
| `DELETE FROM outbox WHERE clientMsgId = ?` | `SyncEngine` ack path | 9 | 0 |
| Receipt over 5 022 rows | `SyncEngine.applyReceipt` | 662 732 | 0 |
| the same with the FTS triggers dropped | — | 291 101 | 0 |
| Receipt that changes nothing (seq ≤ 100) | `SyncEngine.applyReceipt` | 718 | 0 |

Two things fall out of that table. The ack read the whole message table on every
send, and 56 % of the work of a delivery receipt is FTS4 re-indexing rows whose
text did not change: the triggers `__messageFts_bu`/`__messageFts_au` fire on any
`UPDATE message`, and a receipt only writes `status`.

## What was fixed here

An index on `message(clientMsgId)`, migration `v18-messageClientMsgId`. Every
answer about a message we sent finds it by that column, and without the index
each answer was a full table scan: 60 363 virtual machine steps against 182 with
it, 20 060 fullscan steps against none, and the plan becomes a covering index
search. On the device the ack measured 3 ms warm before and below the trace
resolution after, on a chat of 20 061 messages; the scan grows with the chat, the
index lookup does not.

This is not what causes the stutter. It is the one thing in the send path whose
cost was proportional to the size of the chat and which is fixed by six lines.

## What is left, as separate tasks

Ordered by what the numbers say they are worth.

1. **The feed window must shrink again.** `FeedWindow` only ever raises its
   capacity (`grow`, `anchor` with `max`), so a jump into the history leaves the
   window at the size of the whole conversation for as long as the screen lives.
   Every measurement above with a frame over 250 ms is taken in that state. The
   window has to come back to its page size once the reader is at the bottom
   again, and the jump has to hold the target with a bounded number of messages
   below and above it instead of stretching to the newest.
2. **A keystroke must not refetch the feed.** The draft is written on every
   change and the feed observation's region covers the `chat` table, so five
   characters cost seven full window refetches. Either the draft leaves the
   observed region (its own table or `kv`), or it is written on a debounce, or
   the feed stops reading the chat row inside the window fetch.
3. **Narrow what the feed observes.** Beyond the draft, every incoming envelope
   updates `lastSeq`/`syncedSeq` and every peer read updates `peerReadUpTo` on
   the same row, and each of those refires the whole window fetch. During a
   burst that is one full re-read, rebuild and diff per message.
4. **The FTS triggers should look at the text.** `__messageFts_bu`/`_au` fire on
   any update of `message`; adding `WHEN new.text IS NOT old.text` removes 56 % of
   the cost of a receipt at this size and does nothing else.
5. **The pinned bar has to find its message outside the window,** and its tap has
   to go through `ensureLoaded`, or the pin is invisible and inert in exactly the
   chats where a pin is worth having. Worth doing after task 1: as it stands the
   jump it would trigger is the expensive path.
6. **A pin should apply locally,** rather than waiting for the next chat-state
   sync to come back from the server.
