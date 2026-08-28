# The hero transition bubble ↔ viewer — live run

2026-08-29, simulator `msngr-7b-anim` (iPhone 17, 2763149F), the `delta7b`
account, a photo message in the chat with `echo7b`.

## The change

`MediaViewerPresenter.present` takes the tapped thumbnail (`from:`); its
picture, frame and corner radius become a `MediaViewerHero`. The viewer's
window appears without the old fade, and an overlay copy of the picture flies
from the bubble frame into the aspect-fit full-screen frame under a spring
(0.38 s), the black backdrop rising with it; when the flight lands, the real
pages take over. Closing — the X, or the swipe down past the threshold —
flies the picture back into the bubble frame, starting from wherever the drag
left it; the window is then removed without a fade. The flight back only runs
while the viewer still shows the page it opened on; after paging to another
photo the close falls back to the old fade. A viewer opened without a source
view (the gallery) keeps the fade both ways.

## What was seen

Recorded at 25 fps (`simctl io recordVideo`), the frames in
`2026-08-29-hero-viewer/`:

1. A tap on the photo bubble: the picture grows out of the bubble across the
   feed and lands in the fitted frame — `open-midflight.png` holds the
   mid-flight (the picture at half-way size over the dimming chat).
2. The X: the picture shrinks back into the bubble's place over the chat
   coming back through — `close-midflight.png`.
3. After the landing the viewer behaves as before: paging, zoom, share, the
   swipe down.

## Checks

- `MsngrTests` pass (`scripts/build-slot.py xcodebuild … test
  -only-testing:MsngrTests`).
- The recording above; the app built and driven live on the simulator.
