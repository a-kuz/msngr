# Media appears in the feed at the moment of sending, run

Two fresh simulators (`run-media`, `run-media-peer`, both iPhone 17 / iOS 26.5),
against the shared `wrangler dev` stand on :8787. Two fresh accounts,
`runmediaa` and `runmdiab` (a stray dropped keystroke, harmless), direct chat
between them. Build from the branch's own DerivedData
(`Msngr-harbcogwctuvwxfpmpccfsixzoiw`), `MSNGR_APP_ID=ai.enface.Msngr`. Test
media: five solid-colour JPEGs and one 4-second synthetic `testsrc` MP4
(1280x720, ffmpeg), plus stock photos already in the simulator's seed photo
library (a waterfall, a bed of flowers) used for cases that needed real detail
to tell a blurred placeholder from a resolved one — a flat test colour looks
identical blurred or sharp. Timings below are wall-clock deltas from the
picker's "confirm" tap, sampled by polling `simctl io screenshot` every
0.4–0.7 s (screen recording via `simctl io recordVideo` produced a corrupted,
non-seekable stream partway through and was abandoned in favour of polling).

## Single photo

Confirmed a detailed stock photo (flowers). By the first screenshot after the
picker closed the bubble was already in the feed: correct 4:3-ish frame, flat
placeholder, a "sending" clock glyph. The frame-accurate check (via the one
usable stretch of the recording, before it corrupted) put the flat-placeholder
frame and the fully-resolved sharp frame about 1.5 s apart. Sent (single
check) shortly after.

## Album, 5 photos

Confirmed 5 distinct solid colours (yellow, purple, green, blue, orange) at
once. By t≈2.0s the mosaic was already in the feed with the correct 2-over-3
layout and all 5 tiles as flat gray placeholders — no reflow, no missing
tiles, no duplicate row. By t≈3.7s every tile showed its real colour. Sent
(single check) somewhere between t≈3.7s and t≈7.2s (not narrowed further).
Tiles resolved independently of each other, as designed — nothing here
showed one tile blocking on a sibling.

## Video

Confirmed the 4-second colour-bar clip. By t≈2.0s the bubble was in the feed
with the correct aspect ratio (from the track's `naturalSize`, not the 16:9
default), a sharp poster frame, the play glyph overlay, and already a single
check (sent). This is a best case — a 4-second synthetic clip transcodes and
uploads almost instantly — so the ~2s figure says the reordered pipeline
(track size → poster + BlurHash → only then the transcode) does not gate the
bubble's appearance on the transcode, not that every video will resolve this
fast. A longer or higher-resolution clip was not tried.

## Not covered: paste from the clipboard

`onSendImages` shares the exact code path with the picker
(`sendPhotoSources`/`processPhotoSource` — the only difference is the source
of the raw bytes), so there is no reason to expect it to behave differently,
but it was not exercised live. `xcrun simctl pbcopy` writes to the
simulator's pasteboard, which mirrors the host Mac's general pasteboard —
and on this shared host, another agent's session overwrote it mid-test with
an unrelated shell command, which then pasted into the message field instead
of the intended test image. Repeating this reliably needs either an isolated
host or a way to paste that does not round-trip through the shared clipboard;
neither was pursued further given the time already spent. The stray pasted
text was left unsent in `runmdiab`'s draft field — never sent, no effect on
the server or the peer.

## Defect found and fixed along the way: sender's own bubble stuck on the blurhash forever

First live run of the single-photo case never got past the flat placeholder,
even minutes later — confirmed via the database that the message was fully
sent (`mediaId` set, `localPath` cleared, `status=1`). `MessageCell
.configureMedia`'s "same message reconfigured in place" fast path (written
for reactions and delivery ticks, back when a message's media never changed
after the row existed) repositions existing image views but does not reload
them; three-phase sending now updates that same row's media several times in
place, so every one of those updates hit the fast path and none of them ever
re-fetched the image. Fixed in `MessageCell.swift` by fingerprinting each
media slot (`blurhash`+`mediaId`+`localPath`+`thumb*`) and reloading only the
slots whose fingerprint moved, keeping the reposition-only behaviour for
everything else (reactions, ticks, unrelated slots in an album). Confirmed
after the fix: the flowers photo, the 5-tile album and the video all resolved
live, in the same session, no relaunch needed.

## Not seen

No duplicate messages, no reordering, no flicker of the row itself across any
of begin → preview update → finalize, across single photo, album, and video.
The mosaic layout stayed put throughout an album's resolution. `swift test`
in MsngrKit: 359 tests, 5 skipped (no server), 0 failures, both before and
after the `MessageCell` fix.
