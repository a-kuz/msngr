# 2026-08-19 — the long-press with the keyboard up

Two owner-reported defects, one interaction: the context menu opened behind the
keyboard with only «Ответить» reachable, and the lifted bubble drew a second
offset outline behind itself. Both fixed in `c5c0ab4`.

## Causes

- **Menu under the keyboard.** `MessageContextOverlay.targetBubbleFrame()` laid
  the card out against the window's safe area, which the keyboard is not part
  of, so with the keyboard up the card landed behind it.
- **Doubled outline.** Nothing hid the source bubble while the overlay was up.
  The scrim's gradient mask is transparent exactly at the selected message, so
  whenever the snapshot moved away from its origin the original bubble read
  through the ultra-thin blur as a second outline with its own tail. Without
  the keyboard the target usually equals the origin and the copies overlap,
  which is why the defect only surfaced in this pairing.

## The fix

The overlay sends the keyboard down as it opens (`window.endEditing(true)` in
`MessageContextOverlay.present`, after the origin frame is captured so the lift
still starts under the finger); the composer keeps its draft. The source bubble
is hidden for the overlay's lifetime and shown back when the overlay leaves.
Dismissal returns the snapshot to the bubble's current frame rather than the
remembered origin, because the feed relayouts underneath once the keyboard
goes; a bubble that left the hierarchy gets the old origin as a fallback.
`prepareForReuse` unhides the bubble so a reused cell cannot inherit a hidden
one.

## Live check

Simulators `longpress` (Alice) and `longpress-b` (Bob), fresh users, three
messages sent, draft «Draft in progress» typed, software keyboard up.

- Long-press on a bubble with the keyboard up: the keyboard goes down, the
  reaction bar, the lifted bubble and all seven actions are on screen
  (`2026-08-19-longpress/menu-open.png`); the bubble is one shape, no second
  outline.
- Closing the menu returns the bubble into the feed at its actual position and
  the draft is still in the composer (`2026-08-19-longpress/after-close.png`).
- Long-press without the keyboard: unchanged behaviour, single shape, full
  menu.

## Gate

- `make check DEV_UDID=14C70E21-…` — green at the final commit (build,
  MsngrKit `swift test`, 176 MsngrTests, server smoke on a throwaway stand,
  no fresh simulator crashes). Two red attempts on the way: the first died
  before the tests because a fresh worktree has no `server/node_modules`
  (`Cannot find package 'ws'`; `npm install` in `server/` fixed it), and one
  run lost the smoke's «ack precedes push» check by 2 ms — a race between two
  concurrent arrivals, logged in `docs/qa/defects.md`, green on the rerun of
  the same code.
- `make uicheck DEV_UDID=FA8C5DBF-…` — green, 21 of 21, on a clean install.
  Two red runs on the way, neither about the product change:
  - `testB_SendTextAppearsInFeed` failed once on device state left by an
    earlier aborted run (the app was not uninstalled before the retry);
    green on a clean install.
  - `testH_PulseConsoleOpensOnLaunchArg` was red on this branch and on main
    alike: Pulse 5 (`bc528f7`) draws the console title as a toolbar item and
    exposes no navigation bar named «Console», so the smoke waited on a bar
    that never comes while the recording video shows the console open. The
    smoke now anchors on the console's Filters button (`f13888e`), verified
    against the live accessibility tree.

## The shared stand

During the run the shared `wrangler dev` on :8787 stopped answering: workerd
accepted TCP and never replied, 0% CPU, and a file-watch nudge tore the
listener down without a respawn. The process (daemonized, cwd
`~/ws/msngr/server`) was killed and started again with the same command over
the same persist directory; the state survived — the test users reconnected
over `/ws` on the first probe. Nothing under `server/.wrangler` was wiped.
