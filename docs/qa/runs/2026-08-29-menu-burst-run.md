# The reaction burst waits for the context menu — live run

2026-08-29, simulator `fable-shaders` (iPhone 17, E03551E2), the `alfa`
account against the shared stand, the `Random` group on screen.

## The change under test

A first reaction picked in the context menu's emoji row used to fire the
burst while the menu's dismissing blur still covered the feed, so the 1.4 s
effect played behind it (defect found in the 2026-08-29 reaction-burst run).
Now `MessagesViewController.burstIfReactionLanded` hands the burst to
`MessageContextOverlay.afterDismiss`: with no overlay up it runs at once, and
with the menu on screen it waits for the dismissal animation to complete and
asks the cell for the bubble's position then, since the feed relayouts under
the menu. `ShaderEffectPlayer` also counts the effect's lifetime from the
moment the program reports ready instead of from `play()`, so a cold compile
no longer eats the visible window; a failed or hung compile still takes the
canvas down at `compileTimeout + duration` at the latest.

## What was seen

Long-press on «recursion breaker second pass» → the menu with the emoji row
over the blurred feed (`2026-08-29-menu-burst/menu-open.png`) → tap ❤️:

1. The blur leaves the screen with no confetti behind it
   (`blur-gone-no-burst.png`).
2. The confetti plays over the uncovered feed, the ❤️ already standing on
   the bubble (`burst-peak.png`, `burst-fade.png`).

The log reads the same story, timestamps within 8 ms of each other and all
after the dismissal:

```
22:01:16.872 [shader] reaction landed 0→1, bursting
22:01:16.875 [shader] effect reaction starts
22:01:16.880 [shader] effect reaction ready
```

## Checks

- `swift test` in MsngrKit: 442 tests, 0 failures (18 skipped).
- MsngrTests on `fable-shaders`: TEST SUCCEEDED.
- The `alfa` home was pulled back after the run.
