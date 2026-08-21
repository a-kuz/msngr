# The media viewer over an album, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`. A three-photo album was sent into the direct chat with `charlie`
through the attachment sheet and the system picker (stock library photos); the
bubble was in the feed the moment the picker confirmed, as the mosaic of one
large tile over two. The strips are consecutive frames of a 15 fps screen
recording of the viewer.

- The viewer opens fullscreen from a mosaic tile, with the close cross, the
  share button and three page dots.
- `01-album-paging.png` — a swipe left: the first photo slides out and the
  waterfall slides in, the dots move to the second page.
- `02-paging-back.png` — the third photo, and a swipe right returning to the
  second: paging works in both directions.
- `03-swipe-down-close.png` — a swipe down: the viewer lets go and the dimming
  dissolves back into the chat feed.

Pinch zoom and sharing from the viewer stay unverified: a two-finger gesture
is not something `idb` drives, and the share sheet was not exercised.

The same session fed the media cache for the settings check: after the album
and the viewer the «Очистить кэш медиа» row showed «1,2 МБ», and tapping it
emptied the cache directory on disk — but the label kept showing «1,2 МБ»,
because it was computed at render time with no state behind it. Fixed in this
change: the size lives in view state, refreshed when the row appears and
right after the clear. Re-run with the fix — `04-cache-size-before.png` shows
«1,2 МБ» after re-viewing the album, `05-cache-cleared-live.png` shows the
label at «0 КБ» immediately after the tap, without leaving the screen.
