# Feed extras: sticky date separator and sender avatars, run

Two fresh simulators (`feedextras`, `feedextras-b`, iPhone 17 / iOS 26.5) as
the fixture accounts `alfa` and `bravo`, on the shared stand at :8787. Alfa's
screen is the one under test; bravo drives the group from the second device by
really typing and sending, so every incoming message travels the whole E2EE
path. Screenshots are in `2026-08-21-feedextras/`.

Bravo sent 8 consecutive messages into «Design», then 6 more, forming two runs
in one day next to the fixture's yesterday history, and one more message while
alfa stood in history for the anchor check. (The last message reads as garbled
Russian — the simulator keyboard had switched to a Russian layout under
`idb ui text` and autocorrect finished the job. The typed bytes were delivered
exactly; the content is irrelevant to what the run checks.)

## Sender avatars

- `01-group-avatars-bottom.png` — the «Design» feed at the bottom: two runs of
  consecutive Bravo messages, each with the sender's avatar on its last bubble
  only, the bubbles above shifted by the same column and left empty; the
  author name sits on the first message of each run. The single fixture
  messages from Bravo and Charlie each carry their own avatar (a run of one).
- Initials fallback drawn over the same per-name gradient the chat list uses
  (the fixture accounts have no photos, so the fallback is what the run shows;
  the photo path goes through the same `AvatarImageLoader` the list draws
  with).
- Direct chats and outgoing group messages show no avatars and no column
  (checked in «Bravo Service» direct and by alfa's own «Reading you» bubble in
  «Standup»; unit-covered in `FeedExtrasTests`).

## Sticky date separator

- `02-sticky-today-mid-scroll.png` — mid-scroll: the floating «Вчера» capsule
  pinned under the header while yesterday's messages pass the top edge, the
  real «Сегодня» separator scrolling in the feed below it.
- `03-sticky-boundary-handoff.png` — the same scroll one phase earlier: a
  single «Сегодня» capsule pinned while today's run passes. The first take of
  this shot caught a defect — the 0.3 s fade-out left two «Сегодня» capsules
  on screen for a beat at the boundary. Fixed in this branch (the handoff to
  the real cell is now instant) and re-shot: no double.
- `04-sticky-yesterday.png` — the boundary itself: the real «Вчера» cell holds
  the top edge and the floating capsule has yielded to it.
- At history start and while the feed rests, the capsule is hidden; it fades
  out about a second after the scrolling stops (observed live, not captured —
  a still cannot show a fade).

## The anchor under an incoming message

- `05-incoming-in-history-no-jump.png` — alfa standing at the top of history
  when bravo's message arrived. A pixel diff of the before/after screenshots
  shows 2 096 changed pixels, all in one cluster: the «1» badge appearing on
  the scroll-down button. The feed itself did not move by a pixel, and the
  unread path (badge on the button) kept working.

## Checks

- `MsngrTests` on the run simulator: 196 tests, 0 failures (6 skipped —
  device-only). New units in `FeedExtrasTests`: who reserves the avatar
  column, who carries the picture, how the plan shifts and narrows the bubble,
  and what the sticky label shows at a day boundary, over the real separator,
  and at history start.
- `make check` after the merge, in the background; log in
  `.claude/gates/run-feedextras.log`.

Both simulators were deleted after the run; the fixture homes were pulled back
(`fixture.py pull`) with the moved-on Design history inside.
