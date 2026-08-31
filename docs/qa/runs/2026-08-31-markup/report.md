# Photo markup before send — live run, 2026-08-31

Simulator `fable-markup` (iPhone 17, iOS 26.5), fixture `alfa`, the shared
stand. Build from the working tree.

## What ran

1. Attach → «Фото или видео» → one stock photo picked. The photo landed in
   the input bar as a waiting thumbnail instead of leaving at once (the new
   staging path; a selection with a video or a GIF keeps the instant path).
2. A tap on the thumbnail opened the markup editor. Drawn in one session: a
   red pen stroke, a red arrow (its head visible), a blue ellipse, a region
   blur, a «123» label typed through the text tool. Undo took the last step
   away, redo brought it back — checked on the ellipse.
3. «Готово» put the edited picture back into the bar; send delivered it to
   the chat. The bubble shows every stroke (`chat-after-run.png`, upper photo).
4. The sent photo, reopened in the full-screen viewer, shows the pencil
   button. It opened the same editor over the delivered picture; a second,
   larger blur went on, «Готово» closed the viewer and put the copy into the
   input bar; the copy was sent as a new message. The original message stayed
   as it was (`chat-after-run.png`, both photos side by side).
5. The blur edge: after the owner's ask mid-run the blur was rebuilt to fade
   out through a mask (CIBlendWithMask over a feathered rectangle); the
   second photo in the shot carries it — no seam, a smooth falloff. A third
   editor session blurred the «123» digits to unreadable and was discarded
   through the cancel confirmation («Discard markup»), leaving nothing behind.

## Checks

- `MsngrTests/MarkupTests` — 9 tests: history undo/redo, rotation round-trip
  and the pixel landing of a clockwise turn, crop size, blur softening inside
  the region and sparing the outside, arrow and text ink, preview scale, the
  straight-line recognizer accepting a line and refusing a scribble. Green
  (`xcodebuild test -only-testing:MsngrTests/MarkupTests`).
- The straighten-to-arrow hold gesture is exercised by the recognizer's unit
  tests; `idb` cannot hold a finger still mid-drag, so the live half of that
  gesture was not driven from outside.

## Not covered

- The chat gallery opens the same viewer without a chat to hand the copy to,
  so the pencil button is absent there by design.
