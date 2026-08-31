# Polls — live run, 2026-08-31

Simulator `fable-poll` (iPhone 17, iOS 26.5), the shared stand. Two sides:
the `alfa` fixture and a fresh `pollpeer` account created with `msngrfixture
knock` (the alfa↔bravo, alfa↔charlie and alfa↔roundpeer pairs were unusable:
bravo's and charlie's homes are corrupted — logged in defects.md — and
roundpeer's frozen home answers `no_session`, the already-open severed-pair
defect).

## What ran

1. alfa accepted pollpeer's request, opened Attach → «Poll», composed
   «2027?» with three options (the third added through «Add an option»),
   sent it, and voted for the first: the mark popped, the bars grew to
   100/0/0, «1 voted».
2. The same simulator was handed the pollpeer home. The chat list previewed
   the poll as «📊 2027?»; the incoming bubble showed plain circles and
   «1 voted» — no shares before voting.
3. pollpeer voted for the second option: the shares appeared animated and
   already carried alfa's vote — 50/50/0, «2 voted»
   (`pollpeer-both-votes.png`).
4. Revote to the third option moved the share (50/0/50); a tap on the chosen
   option retracted the vote and the bubble returned to plain circles,
   «1 voted». A final vote for the second option went out.
5. Back on alfa: 50/50/0 with alfa's own mark on «10» and «2 voted» — the
   peer's revotes and retraction collapsed into the right final state
   (`alfa-final-50-50.png`). alfa's database holds
   `pollVotes = {alfa:[0], pollpeer:[1]}` on the poll row, checked with
   sqlite3.

## Checks

- `PollTests` in MsngrCoreTests — 5 tests: the poll round-trips through the
  database, a vote replaces and retracts, a vote arriving before its poll
  buffers and lands, `pollVote` is a rowless silent service kind while the
  poll itself is content, the push preview carries the question. Green
  (`swift test --filter PollTests`).
- A false alarm worth recording: after the run the fresh chats looked
  "sunk" below week-old rows in alfa's list — the week-old rows turned out
  to be pinned (five pins, not four), and the rendered order matches the
  database exactly.
