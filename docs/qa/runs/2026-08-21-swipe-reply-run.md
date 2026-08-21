# Reply by a swipe and the quote rendering, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`, in the direct chat with `charlie`. The strip is consecutive frames of
a 30 fps screen recording.

- `01-swipe-drag.png` — a swipe right over an incoming text bubble: the bubble
  follows the finger, a reply arrow is revealed on its left, and the offset
  stops at its cap while the finger keeps going — the resistance is the
  flattening, visible as the bubble holding the same displacement across the
  frames. Releasing put the reply strip above the composer with the quoted
  author and text. Haptics are not observable on the simulator.
- `02-text-quote.png` — the sent reply renders the quote block above its own
  text: the author's name and the quoted line, text on text.
- `03-album-quote.png` — a swipe over the album bubble and a reply to it: the
  quote block reads «Вы / Альбом» with a thumbnail glyph — a media quote with
  the author name instead of an identifier. Photo, video, voice and file
  quotes were not exercised in this run.
