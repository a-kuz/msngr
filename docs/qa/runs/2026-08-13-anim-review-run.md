# Frame-by-frame verification of the animations

Run date: 2026-08-13. Key frames in `2026-08-13-anim-review/`.

## Stand

Two simulators, `anim-a` and `anim-b`, iPhone 17, iOS 26.5, palette graphite.
Build from main (`ba585e8`) against the stand on localhost:8787, users `anim7`
and `anim8`.

Slow Animations in Simulator.app had no effect on these simulators: the checkbox
was ticked and a push transition still took a steady 0.5 s, and
`UIAnimationDragCoefficient=5` with an app restart did nothing either. Capture
was therefore a burst of screenshots about 0.16 s apart, which is enough for a
0.6 s spring — around four intermediate frames were expected.

## 1. The outgoing bubble's flight — not visible

Expected: the bubble starts small at `scale 0.15` near the send button and
springs into place (`MessageCell.animateSendFlight`, a 0.6 s spring at damping
0.72, text fading over 0.25 s).

What the frames show: between two neighbouring frames 0.16 s apart the composer
empties and the bubble is already at its final position, full size, fully
opaque, text and ticks visible. Three repeats produced no intermediate frame of
the flight, neither in the 0.16 s screenshot burst nor in `recordVideo` at
19 to 45 fps.

Key frames: `send-frame0.png` (composer with text) → `send-frame1.png` (bubble
already in place, 0.16 s later), and then 3.7 s of zero pixel difference. The
video montage shows the same thing (`send-video-montage.png`).

Hypothesis at this point, unconfirmed: a second snapshot update lands right
after the optimistic insert (pending→sent), `contentEqual` comes back false,
the cell is reconfigured or reloaded and the animation is cut off within
milliseconds. On `s3-01` the ticks are already doubled, so the ack really does
arrive instantly against a local stand.

## 2. The context menu on a long press — works

Opening, at a 0.16 s step:

- `menu-open-1-press.png` — the press highlight on the bubble;
- `menu-open-2-cascade.png` — the blur already covers everything and the emoji
  row is growing in a cascade: the first two at full size, the third still a
  dot, the rest absent; the list menu has nearly finished growing;
- `menu-open-3-full.png` — all six emoji in place, the menu complete.

The cascade is plainly visible, half the row caught in one frame. The blur
reaches full strength faster than the capture step, going from nothing to full
in 0.16 s or less, so the wash-in exists but is brief.

Closing, by tapping outside (`menu-close-0..3.png`):

- `close-1` — the menu and the emoji row contract and the bubble starts moving
  back;
- `close-2` — the blur dissolves, the bubble copy is halfway to its place in the
  feed;
- `close-3` — the chat is fully restored.

Smooth, with real intermediate states, over roughly 0.4 to 0.5 s.

On aesthetics: in `close-1` the bubble's ghost travels over the still-visible
menu, which reads as intentional rather than as an artefact. The menu and the
emoji capsules hold good contrast against the blur.

## 3. The incoming message — not visible

Expected: the bubble rises from below on a spring
(`MessageCell.animateAppearance`, `translationY` 14 with `scale 0.96`, alpha 0.4
to 1, a 0.42 s spring).

What happened: across two independent runs, "Incoming wave" and "wave two", the
incoming bubble appears between neighbouring frames 0.16 s apart, already in its
final place and fully opaque. Not one frame of the rise or of the
semi-transparency. A 0.42 s spring should have given about three.

Key frames: `incoming-frame0.png` → `incoming-frame1.png`.

## Reading of the three

The menu animates as designed. Both bubble-appearance animations exist in the
code and neither reaches the screen; in both cases the bubble materialises at
once. The pattern being identical points at the insert path
(`MessagesViewController.applySnapshot` → the `performBatchUpdates` completion)
rather than at the animations themselves, and the capture method is not at fault
either, since it caught the context menu's intermediate states in the very same
frames.

Hypotheses, unconfirmed at the time: the `reloadData` branch running instead of
`insertItems`; `cellForItem(at:)` returning nil in the completion; the cell
being reconfigured instantly by a second snapshot update.

## After the fix, 2026-08-14, users animfix1 and animfix2

NSLog diagnostics on a live simulator confirmed the cause. The completion of an
unanimated `performBatchUpdates` ran before the inserted cell existed, so
`cellForItem(at: 0)` returned nil and the animation never started at all; on top
of that the pending→sent ack arrived about 15 ms later and `reloadItems(0)`
rebuilt the cell. The fix is a `layoutIfNeeded` after the batch update and a
synchronous animation start outside `performWithoutAnimation`, with content
updates that keep the same height reconfiguring the cell in place instead of
rebuilding it.

Frames after the fix, from video at 19 fps, roughly a 0.05 s step:

- the outgoing flight: `fix-send-0-start.png` → `fix-send-1-mid.png` (bubble in
  flight, semi-transparent, no text yet) → `fix-send-2-textfade.png` (in place,
  text fading in) → `fix-send-3-overshoot.png` (the spring's bounce) →
  `fix-send-4-final.png`;
- the incoming rise: `fix-incoming-1-low.png` → `fix-incoming-2-mid.png` →
  `fix-incoming-3-high.png` (below its final position, opacity climbing) →
  `fix-incoming-4-final.png`;
- scrolling history: six swipes fired the appearance animation zero times
  according to the log, and the video shows cells arriving without a rise or a
  scale.

## Defects noticed in the frames

On the receiving side (`anim8`) the chat header and the chat list show «…» in
place of the sender's name (`recipient-header-no-name.png`,
`recipient-list-no-name.png`), while the sender sees the peer's name normally.
The peer's profile never arrived on the receiver, neither while the message
request was pending nor after it was accepted.

The graphite palette holds up: dark blue outgoing bubbles read well on the cream
background, the orange ticks contrast against the dark bubble, and the white
incoming bubble with its shadow is fine. The composer and the reaction row sit
consistently on the blur with no compositing artefacts.
