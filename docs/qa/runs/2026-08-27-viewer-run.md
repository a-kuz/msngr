# The media viewer: double tap, share, and a close button under the player

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5) with
the `alfa` home, against the shared stand on :8787, over the album of the
video run of the same day (a still and two clips) and the debug seed's
attachments.

## Seen

- Double tap on a photo page: the still fills the screen at 2.5× (the frame
  of the 4:3 still overflows the width and the page dots stay in place), the
  next double tap brings it back to 1. Two taps 100 ms apart from `idb` count
  as the double tap.
- Share on a video page: the sheet opens on the cached file («Видео · 302 КБ»)
  with «Скопировать», «Сохранить видео», «Добавить в общий альбом», «Сохранить
  в Файлах».
- Paging: the album opened on the tapped tile (page 2 of 3 for a video, the
  dots under it), and the still opened on page 1.

## Found and fixed

Over a video the viewer's close button sat exactly under the system player's
picture-in-picture glyph, and the tap went to the glyph: the viewer stayed
open. The page is now `AVPlayerViewController` without picture-in-picture, and
the close button lands on both a photo and a video page (checked by the
composer being back after the tap, both times).

## Not covered

Pinch zoom: the simulator driver has one finger. It shares its state with the
double tap (`scale`, `lastScale`), so the double tap exercises the same path
without the gesture itself; a two-finger run on a device is still owed.
