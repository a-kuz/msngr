# Muted autoplay in the feed, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`, a 4-second generated test video sent into the direct chat through the
attachment sheet.

- `02-bubble-no-glyph.png` — the sent bubble: the video plays in place and the
  play glyph is gone; the tap still opens the viewer.
- `01-looping-frames.png` — four frames of a screen recording one second
  apart: the pattern inside the bubble moves, and past the clip's end it is
  looping.
- The rule: a video whose file is already on the device — its own pending
  source before the upload, or the decrypted cache after a download — plays
  muted and looping; a video that would need a network transfer keeps the
  preview frame and the glyph, so the feed starts no downloads on its own.
- Players pause when their cell leaves the screen and resume on the way back
  (willDisplay/didEndDisplaying), and the first autoplay claims the ambient
  mix-with-others audio category once, so a muted loop does not stop whatever
  the user is listening to; the voice paths set their own category right
  before they run.
