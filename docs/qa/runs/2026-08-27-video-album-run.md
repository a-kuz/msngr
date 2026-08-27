# Videos in the album, the row before the bytes, a ring with the percent

Run on 2026-08-27 on a fresh `iPhone 17` simulator (`solo-live`, iOS 26.5)
with the `alfa` home, against the shared stand on :8787. The library held two
clips made with ffmpeg (20 s of `testsrc2` at 1920×1080 with a tone, 14.4 MB;
12 s of `mandelbrot` at 1280×720, 7.1 MB) and a 1200×900 still, added with
`simctl addmedia`.

## What was wrong

`sendPicked` split a pick into photos and videos: the photos became one
album, and every video went out as a message of its own, whose row was
written only after `loadTransferable` had copied the file out of the library.
A ten-second clip meant a chat with nothing in it for as long as that copy
took, and three videos picked together were three bubbles.

## What changed

One pick is one message. The row goes in with a typed placeholder per item
before any loading starts (`PickedBatch`), photos and videos share the album,
and each slot fills in as its own preparation finishes: the video's poster
frame and aspect first, then the transcoded file. While the message is in the
sending state every tile wears a ring with the percent: the transcode is
polled off `AVAssetExportSession.progress` into the first half, the upload
delegate (`URLSession.upload(for:from:delegate:)`) fills the second, and the
ack clears the store (`MediaProgress`). The play glyph stays hidden under the
ring and comes back with the tick.

## Seen

Three items picked, «✓» tapped: the album bubble was on screen in the first
screenshot half a second later, as a mosaic of three with a ring on every
tile. Frame 2 read 0 % on the still (no preparation to report, the upload had
not begun), 50 % on the 720p clip (transcode done, upload starting) and 7 % on
the 1080p clip. By frame 6 the bubble had the tick, the mosaic had relaid to
the learned aspects (1+2) and the two video tiles carried the play glyph.
Tapping a video tile opened the viewer on page 2 of 3 with the player.

Units: `PickedBatchTests` (a mixed pick is one album with typed slots; a single
video stays a video; the progress store's keys and clearing).

## Not covered

The receiving side: Bravo is headless here, and the envelope of an album with
video slots is the one the receiver already renders (the tile code branches on
`type == "video"` per slot). The camera path (shooting from the sheet) is
still unbuilt, so no other caller of the video pipeline exists.
