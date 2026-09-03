# B63 — a tap stops opening a sticker (2026-09-03, fable-sticker)

Simulator `fable-sticker` (iPhone 17, iOS 26.5), home `guest4` on the shared
stand, chats with `guest12`/`guest13` and the test attachments of one round.

## The cause

The canvas logged every touch it received. A finger that moved more than a few
points and then lifted produced `began` with no matching `ended`, and the next
tap arrived as a second finger (`fingers=1` at `began`, `tap=false` at `ended`)
— the toggle never ran again until the cell was rebuilt, which is what leaving
and reopening the chat did.

The finger's `touchesEnded` was held by the bubble's single-tap recognizer
(`delaysTouchesEnded`, on by default) and dropped when that recognizer failed
on the wandering finger. Switching `delaysTouchesEnded` off on that one
recognizer alone removed the stale finger in the log; the canvas also lifts a
finger whose phase is already `ended` when a new `began` arrives, so no other
recognizer can leave one behind.

Reproduced by dragging ~22 pt inside a sticker and tapping it twice: before the
fix the log showed `stale=1` and no `toggle`, after it every tap toggles.

## What was watched

- Sticker: a tap opens, a second folds, repeated ten times after drags, swipes
  in both directions, a long press with the context menu, a double tap (the
  reaction still lands), backgrounding and foregrounding the app.
- One at a time: opening the second sticker folds the first, a tap on empty
  feed folds the open one (`2026-09-03-sticker-tap-one-at-a-time.jpg`).
- Round video: a tap starts the sound and opens the circle, a tap pauses and
  folds it, the end of the clip folds it, a tap on the feed stops the sound and
  folds it (`2026-09-03-sticker-tap-round-video.jpg`).
- A link in a text bubble still opens the built-in browser.

## Checks

- `MsngrTests`: 338 tests, 3 skipped, 0 failures.
- `MsngrTests/RoundVideoTests`: 9 tests, 0 failures, including the new
  `testExpandedCircleGrowsAndStaysInsideTheBubbleWidth`.
