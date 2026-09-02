# Video streaming: a 48 MB video plays from its first blocks

2026-09-02, branch `run-streaming`. Simulator `streaming-a`
(E067E570-CE7A-4D18-B102-F9C45FE801FE, iPhone 17), receiver logged in as
`charlie2`; the sender is `msngrfixture send --video`, which stashes the
original and lets the outbox encrypt and upload it the way the app does.

The stand is the shared one (`https://msngr.a-kuz.online`) with a private trio
seeded for the run (`alfa2`/`bravo2`/`charlie2`) — the local stand was too fast
to tell streaming from a download: 48 MB over loopback arrives in half a
second.

The file: 90 s of 1280×720 h264, 50 657 846 bytes (`ffmpeg -f lavfi -i
testsrc2`), with a poster frame as the video's preview blob.

## Playback starts before the download finishes

One tap on the video in the feed, journal from the receiver
(`log show --predicate 'subsystem == "com.msngr.msngr" AND category == "media"'`):

```
22:01:27.887  the tap
22:01:31.034  stream 01M1HQXECDZYQC5GKYKHJKYTDE: first block ready
22:01:31.132  stream 01M1HQXECDZYQC5GKYKHJKYTDE: first frame on screen
22:01:40.226  stream 01M1HQXECDZYQC5GKYKHJKYTDE: download complete, 50657846 bytes in cache
```

The picture is moving 9.1 s before the last byte of the file is there.

## A seek forward fetches only what it lands on

Second video, tapped and dragged to about three quarters of the timeline within
two seconds of opening. The debug lines name the block runs asked for
(`--level debug`):

```
22:04:50.919  blocks 52…67   over range 13632320+4194560
22:04:51.102  blocks 71…75   over range 18613360+1310800
22:04:51.786  blocks 138…142 over range 36178080+1310800
22:04:51.786  blocks 125…125 over range 32770000+262160
22:04:51.917  blocks 68…70   over range 17826880+786480
22:04:52.497  blocks 80…95   over range 20972800+4194560
```

The player's seek took blocks 125…150 (33–38 MB into the file) while the
background fill was still at block 80, and the picture came up at 1:06 of 1:30.
The whole file was complete at 22:04:57.

## After playback

The cache holds plain mp4 files of the full 50 657 846 bytes for every video
that was streamed, and no `.partial` is left behind. «Вложения» → «Медиа» lists
them and opens one straight from the cache: the viewer's `first frame on
screen` line appears with no range request behind it.

A photo sent the same way (`msngrfixture send --photo`) arrives and renders:
every attachment of a message now travels in format 2, and only a video's
preview frame stays in format 1.

## Checks

- `swift test` in MsngrKit: 649 tests, 0 failures (18 skipped — the
  integration tests with no stand on :8787). The format itself is covered by
  `ChunkedMediaTests`, the streaming reader by `MediaStreamTests`.
- `node test/smoke.mjs` against a local stand on :8790 — ALL PASS.
- `MsngrTests` on the simulator — TEST SUCCEEDED.

## Noticed in passing

A video that arrives with no preview blob has its whole file downloaded by the
feed to draw the tile (`MessageCell.loadMedia` falls back to the video's own
blob when there is no thumb). The app always attaches a preview frame, so this
is only reachable through a sender that does not; it is what made the first
take of this run look like a full download.
