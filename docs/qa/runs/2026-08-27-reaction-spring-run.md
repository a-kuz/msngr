# The reaction capsule springs in whole

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803. A double tap on an incoming
bubble sets ❤️; the entrance was captured with `simctl io recordVideo` and cut
into frames (the recording is variable-rate, so the burst around the animation
lands at ~60 fps).

## Before the fix

The heart showed as a clipped sliver growing out of the plate's corner: red
pixel spans per frame ran 32→46 wide while the pixel count crawled 24→221 —
a reveal of a full-size glyph, not a scale. The owner called the look out
(«плохо»). Cause and fix are in docs/qa/defects.md (closed).

## After the fix

The first visible frame already holds the whole glyph — 38×38 with the pixel
count growing in proportion to the area (89→218→267→315→325) as the capsule
scales 38→46 over ~80 ms and settles. No frame shows a cut glyph. The owner
watched it live: «анимация теперь выглядит совсем иначе».

The spring itself is `usingSpringWithDamping: 0.6` over 0.4 s in
`ReactionCapsuleView.configure`; with the capsule laid out before the
animation starts, the transform is all that moves.
