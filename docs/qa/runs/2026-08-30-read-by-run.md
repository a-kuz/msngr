# The read-by list of a group message — live run

2026-08-30, iPad Pro 11" simulator (fable-ipad), the shared stand, the
alfa/bravo fixtures swapped on one simulator.

1. alfa sent «Who read this one?» into `Design`. Long-press on the sent
   message → «Кто прочитал» in the context menu → the sheet said
   «Ещё никто не получил»: neither peer had been online since the send.
2. The bravo home took the simulator, opened `Design`, saw the message, and
   was pulled back.
3. alfa returned and opened the same sheet: «Прочитали — 1» with Bravo
   Service's avatar, name and @username (`sheet-read-1.jpg`). Charlie, who
   never came online, is in neither section — the message has not reached
   that device. The message's own tick stayed single, which is the group
   rule working: the tick speaks for the member furthest behind.
4. In the direct chat with bravo the context menu of an outgoing message has
   no «Кто прочитал» — the list only exists where there is more than one
   reader.

Tests: MemberMarksTests (MsngrKit) — what `recordMark` writes comes back per
peer and never for the caller; ReadByRosterTests (MsngrTests, 4) — the split
into read/delivered, the sender excluded, no-mark members skipped, names
sorted.

Also in this run: `grid.py` grew `--press X Y` (a long-press that saves the
same aim shot as `--tap`), after a series of long-presses through raw idb
went wide of the bubble and no aim shot existed to say so.
