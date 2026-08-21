# Chat list reorder on a new message, run

One fresh simulator (`fable-solo`, iPhone 17 / iOS 26.5) as the fixture account
`alfa` on the shared stand at :8787. The incoming traffic is `charlie` driven
headlessly through `msngrfixture send` (added in this branch): it opens the
fixture home, finds the direct chat with the named peer and sends through the
real engine, so the message travels the whole E2EE path. Frame strips are in
`2026-08-21-chatlist-reorder/`; every strip is consecutive frames of a 30 fps
(the first one 20 fps) screen recording of the arrival.

## The reorder

- `01-before-teleport.png` — the state before the fix: the «Charlie Service»
  row is on position 4 in one frame and on position 1 in the next. The
  `.animation(_:value:)` modifier on the ForEach never reached the List's
  structural diff, so the reorder applied without a transaction.
- The fix moves the animation to the emission: `ChatListModel` publishes the
  snapshot inside `withAnimation(Theme.springFast)` whenever the visible order
  of rows changed, and skips the animation for the first fill and for
  emissions that only relabel content. The ForEach modifier is gone.
- `02-after-glide.png` — the same scenario after the fix, with two extra chats
  stacked above so the travel is three positions: the row leaves its slot,
  crosses the two rows above it through intermediate positions over ~0.3 s of
  spring, and lands on top. The rows it passes slide down by one slot in the
  same transaction.
- `03-after-settled.png` — the settle: the preview and the badge update after
  the move, the in-app banner arrives above the list, nothing shifts again.

## The row height and the time label

Reported by the owner while watching this run: the time in the row jumps when
the preview's line count changes.

- `04-time-jump-before.png` — an incoming one-line preview replacing a
  two-line one: the row's content is centered in the cell, so while the height
  animates the title line rides the resize, and the text cross-fade paints two
  time labels a few points apart.
- The fix reserves two preview lines whether the text fills them or not
  (`minHeight` of two `rowPreview` line heights on the preview text), so a
  preview that wraps or unwraps leaves the row's height alone.
- `05-fixed-height-grow.png`, `06-fixed-height-shrink.png` — the same two
  arrivals after the fix: the neighbouring row does not move a pixel in either
  direction, the title and the time stay put, the preview cross-fades in
  place, the badge steps 8 → 9.

## The unread capsule on an increment

Asked by the owner during the run: play the growing count up instead of a
plain swap.

- The capsule now pops — a 0.18 s spring to 1.25× and a 0.32 s spring back —
  and the digits roll through `.contentTransition(.numericText)`. Appearing
  from zero keeps the existing scale transition; the pulse fires only while
  the count grows.
- `07-badge-roll-pulse.png` — consecutive frames of 9 → 10: the capsule
  swells, the «1» holds while the «0» rolls in, the capsule widens for the
  second digit and settles.
