# Particles when a reaction appears — live run

2026-08-29, simulator `msngr-7b-anim` (iPhone 17, 2763149F), the `delta7b`
account on screen, `echo7b` acting over `msngrfixture` against the shared
stand.

## What plays and when

`MessagesViewController.burstIfReactionLanded` fires the reaction burst when
a feed refresh raises a visible message's total reaction count. That is the
designed rule, and this run pinned down what it means in practice:

- a first reaction on a message (0→1) bursts;
- the same user swapping their emoji (🔥→😂) keeps the count at 1 — no burst,
  and no burst is right;
- retracting stays silent.

The paths are instrumented at info level in the `shader` category:
`reaction landed a→b, bursting` / `… but the cell is off screen` before the
effect, `effect <name> starts / ready / failed: …` inside
`ShaderEffectPlayer`, so a future run reads the verdicts instead of guessing
from screenshots.

## What was seen

1. An incoming first reaction (echo7b's 🎉 on a fresh visible message):
   `reaction landed 0→1, bursting` → `effect reaction starts` →
   `effect reaction ready` (00:38:12, compile 30 ms warm), confetti over the
   bubble in `2026-08-29-reaction-burst/burst-peak.png` and the fade in
   `burst-fade.png`.
2. The send burst logs the same way on a message sent from the composer
   (`effect send starts/ready` at 00:37:35).
3. An own reaction set from the context menu (❤️ from the emoji row) lands
   0→1 and bursts too, but the effect plays while the dismissing context-menu
   blur still covers the feed, so it is barely seen — recorded in
   `docs/qa/defects.md`.

## Checks

- `MsngrTests` green (`scripts/build-slot.py xcodebuild … test
  -only-testing:MsngrTests`).
- The log lines above (`log show --info --predicate 'category == "shader"'`),
  the two frames, and the DB rows confirming each reaction transition.
