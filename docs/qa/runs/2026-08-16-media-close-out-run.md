# Media close-out, 2026-08-16

Two fresh simulators, `media-A` (F0A26D73…, @mediaalice) and `media-B`
(5C41FC7E…, @mediabob), both iPhone 17 / iOS 26.5, both real registered devices
with their own keys. Own stand: `wrangler dev` on :8851 with its own
`--persist-to`, D1 migrations applied to it before the first registration.
Build from this branch (attachment seeder extended with album sizes). Every
attachment was sent from A through the normal outbox path and looked at on B,
so nothing here comes from the sender's own cache.

## Video playback: the FAIL from 2026-08-13 is closed

Opening the received video on B loads the asset and plays it. Sampling the
player's accessibility state five times while it ran gave the current position
at 0.335, 0.471, 0.602, 0.737, 0.870, with the transport reading `0:02 elapsed`
and `−0:00 remaining`. On 2026-08-13 the same screen showed a black frame, a
crossed-out play glyph, and `--:-- … --:--`: the AVPlayerItem had not loaded at
all. The sender side plays too. The same video opened on A reports duration
0:02 and reaches position 1.

No new fix was needed. The MIME-to-extension mapping added in 4747a9a is what
makes this work: the cache file is written as `<mediaId>.mp4` and AVPlayer
picks the container from the extension. `MediaInfo.mime` is non-optional and
travels inside the E2E envelope, so the receiver names the file correctly from
the sender's declared type.

One comment on `VideoPlayerPage` claimed range-request streaming and was
corrected. It plays the decrypted file from the media cache; there is no
streaming (see below).

## Blurhash placeholder: observed, with a caveat about the stand

Captured as an A/B of the same sequence. Media cache cleared through Settings
("Очистить кэш медиа", 938 KB, then 0 files on disk), app killed so the
in-memory `ImagePipeline` cache goes with it, then screen-recorded: launch, tap
the chat, watch the feed come in. Then the identical sequence again with the
cache now warm.

Cold run, 0.4 s after the album tiles start sliding in: every tile is a smooth
two-tone gradient with a diffuse light blob where the numeral is, which is the
32×32 blurhash decode upscaled. Numerals unreadable. Half a second later the
digits are legible; at 0.9 s they are fully sharp. Warm run, at the matching
frame of the same animation: the digits are already readable, because the real
photo is drawn the first time the tile appears. Measured over the feed area,
the fraction of strong-edge pixels (|Laplacian| > 40) in the cold run trails
the warm run by 0.3 to 0.4 s through the whole slide-in, and the two meet about
2 s after the tiles first appear.

Caveat worth carrying forward: on localhost the placeholder is only on screen
for a few frames. A second attempt, scrolling into a region of the chat that
had never been downloaded and then holding still, produced nothing to measure.
By the time the flick's deceleration ended (frame-to-frame difference at zero
from 4.9 s onward) the photos had already loaded, and the feed's sharpness sat
flat at 1.115 for the remaining 2.3 s of the recording. The placeholder is real
and the code path runs, but its duration on this stand says nothing about a
phone on a real network. Seeded photos are flat colour and compress hard, all
of the chat's media came to 938 KB, which makes the window shorter still.

## Album mosaic, 2 / 3 / 5 / 10

Sent one album of each size from A. Layouts, identical on both devices:

- 2: two equal columns side by side.
- 3: one tall tile on the left, two stacked on the right.
- 5: a row of two, then a row of three.
- 10: two, two, three, three.

The seeder previously only knew how to send an album of 3. It now takes a size,
and the chat settings section has a button that sends one album of each of
2/3/5/10, which is how these were produced.

## Photo caption and the album status overlay

Caption: the photo arrives on B with "Фото 1" and the time on a white strip
under the image, inside the same bubble. Checked on the receiver, not only on
the sender.

Album status: one capsule for the whole album, on the bottom-right tile, dark
translucent over the photo. On A (outgoing) it reads time plus double ticks; on
B (incoming) time only. No per-tile status anywhere. Same shape on the single
photo and on the video bubble.

## Not done

**Range-request streaming.** Left as plan, and it is not a UI change. The blob
is sealed as one `ChaChaPoly` box over the whole file and `MediaCrypto.decrypt`
verifies SHA-256 over the whole ciphertext before opening it, so a byte range
can be neither decrypted nor checked. Making this work needs a format change,
chunked encryption with per-chunk nonce and tag, plus an
`AVAssetResourceLoaderDelegate` feeding AVPlayer decrypted ranges. Noted on the
roadmap line. The server side is already willing: media GETs come back `206
Partial Content`.

**Muted autoplay in the feed.** Not started. The four verification items above
took the run.

**Album paging in the viewer**, pinch-zoom, swipe-down-to-close: still
unverified. Only the video page of the viewer was exercised.

## Defects seen along the way

Accepting a chat request leaves the feed washed out. After tapping "Принять" on
B the request card gives way to the message list, but the list renders at very
low contrast, images and text visible but bleached, while the header and the
composer are normal. It survived a scroll and two further screenshots, so it is
not a one-frame artefact of the crossfade. Leaving the chat and re-entering
renders it correctly, and it never came back. Not in the media path, and not
investigated further. `ChatScreen` swaps `requestCard` for `messagesList`
inside `withAnimation(Theme.spring)`, which is where I would look first.

Minor: the play glyph on a video preview is white at 0.9 alpha with no
backdrop, and on a light thumbnail (the seeded orange frame) it nearly
disappears into the image. The status capsule, the only other overlay on media,
does have a dark backdrop.

Minor: the "Очистить кэш медиа" row keeps showing the old byte count after the
cache is emptied. The size is read once per body render and nothing invalidates
it. The files really are gone.

## Stand notes for whoever runs this next

`idb ui text` types through the hardware keyboard and maps to whatever input
mode is active; on a fresh simulator that is Russian, so "mediaalice" arrives
as "ьувшффдшсу". Two ways out: tap the globe key once while the software
keyboard is up, which fixes it for the rest of the session, or push text
through `xcrun simctl pbcopy` and the Paste menu item. Writing `AppleKeyboards`
into the device's Preferences domain and rebooting did not help.

The worktree needs its own `npm install` under `server/` before `wrangler dev`
will bundle, and its own `wrangler d1 migrations apply msngr --local
--persist-to <dir>` before registration stops returning http_500.
