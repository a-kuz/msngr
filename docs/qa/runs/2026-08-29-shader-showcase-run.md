# The shader showcase, live run

2026-08-29, simulator `showcase` (iPhone 17, iOS 26.5), the shared stand at
msngr.a-kuz.online, build from `6b60939`. The demo accounts are `demo`,
`nova`, `iris` (`msngrfixture showcase`), the presenter's home installed with
`scripts/fixture.py install demo <udid> --launch`.

## What was seen

1. **The chat list.** Nova's avatar is the nebula with its halo past the
   circle; the «Showcase» group's planet carries moons that orbit outside the
   avatar and cross the row. Both live under the budget.
2. **The chat with Nova.** The aurora behind the feed: a pale dawn in the
   light theme, a night with stars and green ribbons after switching the
   appearance to dark, back and forth without reopening the chat. The first
   open draws over the theme background while the shaders compile (no black
   flash), and since `6b60939` the bubble shaders and the header's avatar are
   there without a scroll.
3. **The stickers, each answering a tap.** Pond: rings from the finger and
   from its own rain over a sandy rim. Fireworks: a rocket to the tapped
   point, one on its own every few seconds. Eye: the gaze glides after the
   finger, a tap blinks it. Ink: the accent-coloured thread rises and stirs.
   Clock: the hands agreed with the status bar (23:28, 00:17, 00:25 across
   the run).
4. **The bubble shaders.** The foil text shifts its bands as the bubble moves
   up the screen; the embers burn under readable white text; the status time
   reads over both.
5. **The long press.** Lifting the foil text keeps the shader running in the
   lifted bubble (the owner's report; the overlay lays a live canvas over the
   snapshot). The action card and the reaction bar sit around it as usual.
6. **The pack and the send.** The sticker panel shows all seven tiles drawn
   (before `6b60939` every tile was black); the heart sent from it lands in
   the feed and animates.

## Defects found and fixed during the run

- A canvas denied a budget slot could stay empty until the next layout
  (black panel tiles, empty bubble shaders on first open, the black header
  avatar earlier); closed in `6b60939`, the held frame retries until the
  drawable produces one.
- The first open of a chat with a shader background held a black screen while
  the program compiled: the background canvas is transparent now
  (`51389df`).
- The owner's two reports — the bubble shader missing under a long press and
  the pond's grid-like bottom — closed in `51389df` and `a646e5d`; the pond
  was retuned twice more after being seen live (calmer waves, sand at the
  rim, dimmer in the dark theme).

## Found in passing, left open

- A theme switch can leave one bubble with its light background and white
  text until the cell is reconfigured (defects.md).
- Fireworks and Ink read poorly against the light sticker-panel background
  between bursts: transparent stickers idle at near-zero alpha there.

## Checks

- `swift test` (MsngrKit): ShaderGalleryTests compile every pass of all
  eleven documents; NotificationContentTests 24/24 after the stale
  unknown-kind fixture was retargeted (`0b2f56f`).
- `make check` started in the background after the commits; its log is
  `.claude/gates/main-showcase.log`.

Zero unreadable messages in the demo chats; no `shader failed` state was seen
on any surface.
