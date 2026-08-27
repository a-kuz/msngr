# Bubble animations: reaction resize and the press dip

Run date: 2026-08-19. Two owner defects: a reaction that changes the bubble
size snapped in a single frame, and a long press on a bubble answered with
nothing until the context menu appeared at 0.35 s. The bar for both is
Telegram on the same simulator.

## What changed

- `MessagesViewController.refreshItem` reconfigured a visible cell in place
  only while its height held, and went through
  `performWithoutAnimation { reloadItems }` otherwise — the size jump was in
  the code. Now every reconfigure of a visible cell runs inside a 0.35 s
  spring (damping 0.86), and when the plan height moved a
  `performBatchUpdates(nil)` joins the same animation: the bubble resizes on
  screen, the neighbours slide, `contentOffset` stays untouched, so in the
  inverted feed the bubble's bottom edge stays anchored.
- Reaction capsules are reused by emoji (`MessageCell.configure`), so a count
  change animates in the same view; a withdrawn reaction shrinks away over
  0.2 s. Media views of the same message survive a reconfigure instead of
  being torn down mid-resize with a blurhash flash.
- A second long-press recognizer with a 0.1 s threshold dips the bubble to
  `scale 0.96` as soon as the touch settles. It runs alongside every other
  gesture, releases on a spring, lets go once the finger moves 12 pt (a
  scroll or a swipe), and hands the transform to swipe-to-reply without a
  restore animation. The context menu opens out of the dip: the overlay reads
  the pressed scale off the presentation layer and starts its snapshot there,
  so the press flows into the lift without a cut.

Commits: `71cb811` (resize in place), `581c8a3` (press dip and lift),
`d55a29b` (width-only inline reaction).

## Stand

Own `wrangler dev` on :8841 with `--persist-to` outside the repository. Two
own simulators, iPhone 17, iOS 26.5, deleted after the run: `bubbleanim-a`
(user `2001`, launched with `MSNGR_PERF=1`), `bubbleanim-b` (user `2002`);
`bubbleanim-c` was created clean for the UI smoke against the shared :8787.
Build from the working tree.

## Live run

One direct chat, a three-line message and a short one. Every step is in
`2026-08-19-bubbleanim/key-moments.mp4` (cut from the full recording) and
`press-dip.mp4`; the frame strips are 20 fps.

- **Height grows and shrinks.** ❤️ via the context menu on the three-line
  bubble: the capsule row appears, the bubble grows, the messages above slide
  up. Withdrawing it by tapping the capsule shrinks the bubble back; the
  capsule scales away. `shrink-frames.png` shows the withdrawal frame by
  frame: the neighbours occupy intermediate positions on every frame — a
  spring, not a jump.
- **Width-only inline reaction.** 👍 on the short «42»: the capsule sits
  inline, only the bubble width changes, and that path animates through the
  same spring (initially it did not — caught in this run, fixed in
  `d55a29b`).
- **Incoming reaction.** ❤️ from the peer device landed on an open chat and
  grew the bubble through the same animated path; the feed did not move.
- **The press dip.** `dip-frames.png`: the bubble visibly sits at 0.96 before
  the menu, then the blur ramps and the snapshot lifts from that very scale —
  no cut between the press and the menu. The emoji cascade and the lift are
  in `press-dip.mp4`.
- **Scroll is unaffected.** A drag that starts on a bubble releases the dip
  after 12 pt of travel; flicks scroll the feed as before.

A reaction picked from the context menu grows the bubble while the overlay's
blur is still dismissing, so the growth itself is masked by the menu's exit;
the capsule-tap and incoming paths show the animation in the open.

## Counters

`MSNGR_PERF=1` on `bubbleanim-a`, whole session traced, four reaction events
(add/withdraw ❤️ on the long bubble, add/withdraw 👍 on the short one):

| Event | feed.ui.apply | bubble.measure | frames > 36 ms in the 600 ms after |
|-------|--------------:|---------------:|-----------------------------------:|
| ❤️ added | 3.1 ms | 1 | 0 |
| ❤️ withdrawn | 1.6 ms | 0 (plan cached) | 0 |
| 👍 added | 2.9 ms | 1 | 0 |
| 👍 withdrawn | 2.0 ms | 0 | 1 × 36 ms |

One plan measurement per reaction at most, no re-measure per animation frame,
no extra feed refetches: the batch update re-reads sizes from the plan cache.
197 801 frames were traced in the session; the only frames past 100 ms sit at
app launch and keyboard appearance, none inside a reaction or press window.

## Tests

- `BubbleResizeTests` (new): a height change on a visible cell keeps the cell
  instance and the layout takes the new height; a capsule survives a count
  change. Green before and after the merge below.
- `make check` (gate-runner) and `make uicheck` (own clean simulator): green
  on the branch before the merge.
- `main` was merged in mid-run (voice, the feed window, Pulse). One conflict,
  in `MessageContextOverlay`: main added `showsReactions` to the same
  signatures this run added `pressScale` to; both parameters kept. The
  reaction grow/shrink cycle was re-run live on the merged build.
- After the merge, `make uicheck` and `make check` were re-run sequentially:
  green. An earlier attempt ran them in parallel in one worktree and lost the
  gate to two xcodegen calls racing on the project file;
  `VoiceTests/testJ_IncomingPlaybackSurvivesTheList` also failed under that
  double load and passed alone on the same simulator right after — a host
  red, not the code.

## Not done

- The double-tap ❤️ path was not exercised live: idb cannot produce two taps
  inside 0.35 s. It funnels into the same `onReact` → `refreshItem` path the
  menu and capsule taps exercised.
- Frame cost on a device was not measured; the simulator numbers above are
  counts, not speed.
