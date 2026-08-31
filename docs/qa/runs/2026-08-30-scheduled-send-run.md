# Scheduled send — live run

2026-08-30, two of my own simulators (`scheduled-alfa`, `scheduled-bravo`),
alfa4/bravo4 against the shared stand. The change under test: a message can
be scheduled for a future time, stays visibly distinct in the feed, can be
edited/rescheduled/cancelled/sent-now before it goes, sends automatically at
its time while the app runs, and — a cold start after the time has already
passed — still sends it on the next connect.

## Ordinary schedule, edit, cancel, on-time send (prior pass, this branch)

alfa scheduled a message for +2 minutes on the send button's long press; the
bubble showed the clock and the due time instead of the ordinary timestamp;
editing the text and cancelling a second scheduled message both worked; at
the due time the first message left and reached bravo, tick and time updating
in place.

One bug found and fixed in that pass: the long-press gesture never fired
because it was attached to a `Button`, whose own tap gesture always wins —
moved it to a bare tappable `Image` with a `simultaneousGesture`. A second bug:
`scheduledFor` was never cleared on the `message` row once the send actually
went out, so the clock mark stayed on a delivered bubble forever — cleared it
in `applySentAck` alongside `seq`/`status`.

## This pass: cold start after the due time, and the context menu

### Cold start

1. alfa scheduled "Cold start plus two" for three minutes out (20:01 → 20:04).
2. Killed the app immediately (`simctl terminate`) at 20:01:57 — well before
   the due time.
3. Left it dead until 20:06, past the due time by two minutes, then relaunched
   with a plain `simctl launch`.
4. The chat list showed it delivered — double tick, timestamp 20:06 (the
   moment of the relaunch's first connect, not the original 20:04) — with
   nothing done by hand. bravo's copy of the same chat confirmed receipt.

This is the exact path `SyncEngine.start()` → the drain's
`scheduledFor IS NULL OR scheduledFor <= now` query relies on: an overdue
outbox row is never specially marked, so the ordinary connect-triggered drain
picks it up the moment the socket is up again.

### Context menu on a scheduled bubble

Long-press on a still-pending scheduled bubble opened a menu with **Send
now**, **Reschedule**, **Изменить** (Edit — this one string was missed by the
localization catalog, worth a follow-up), and **Отмена** (Cancel).

- **Reschedule**: moved a message scheduled for 20:04 out to 20:08 via the
  same date/time sheet used for the initial schedule; it delivered at 20:08,
  not 20:04, confirming the move took.
- **Cancel**: scheduled "Cancel test v2" for +3 minutes, opened the menu
  within seconds and tapped Отмена — the bubble disappeared from the feed
  outright, nothing left behind (matches `cancelScheduled` deleting both the
  `outbox` and `message` rows since neither had gone out).
- **Send now**: exercised implicitly — every message above that shows a
  timestamp earlier than when it was actually confirmed went out because its
  own due time arrived before I could act on it, i.e. the plain "wait for the
  clock" path, not the menu action; the menu item itself renders and is wired
  to `rescheduleSend(clientMsgId:to: nil)`, not separately clicked-through in
  this pass.

Two earlier attempts at the Reschedule/Cancel checks raced their own one-
minute schedule window (my own taps outpaced it) and the message sent before
the action landed — not a defect, just too short a margin for manual taps;
redone with a 3-minute window each time.

## Verified alongside

- `swift test` in MsngrKit: 476 tests, 0 failures, including the 6 in
  `ScheduledSendTests.swift` (future not due, overdue due, cold start leaves
  an overdue row eligible, cancel removes both rows, reschedule then release
  sends at once, editing rewrites the row and the queued payload together).
- Full app build (`xcodebuild ... build`) succeeds with the branch's three
  commits applied in sequence.
