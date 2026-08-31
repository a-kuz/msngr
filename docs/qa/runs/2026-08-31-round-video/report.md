# Round video messages — live run, 2026-08-31

Two simulators against the shared stand: `alfa` (the service fixture) and a
freshly registered `roundpeer` (the alfa↔bravo fixture pair carries broken
ratchet keys from old experiments — hundreds of unreadable rows — so the
two-way checks ran on a clean pair; `msngrfixture knock` registered it and the
home was handed to the second simulator).

## What was verified

- **The circle in the feed.** A seeded round video renders as a circle with no
  bubble, the time capsule centered on its lower edge, muted loop for a local
  file, the play glyph for one not fetched yet. Layout is covered by
  `RoundVideoTests` (square frame, centered capsule, kind previews).
- **Tap for sound.** The circle swells (~7%), a white progress ring runs along
  its edge, sound plays from the top; a second tap pauses. After the owner's
  device report ("noticeable stutter, a second of delay") the player starts
  with `playImmediately`, the audio session is claimed off the main thread,
  and progress publishes at 10 Hz instead of per-frame (every cell in the
  reuse pool subscribes) — the ring smooths the steps with a short animation.
- **The dock.** Scrolling away from a playing circle moves it into a small
  docked circle under the header, ring and all; tapping the dock scrolls back
  to the bubble, the cross stops the sound. Leaving the chat stops it too.
- **Recording.** Tap on the idle mic flips microphone ↔ camera (persisted in
  UserDefaults, verified across a relaunch); hold records with the voice
  gesture (slide-to-cancel, lock), a live circular preview floats over the
  feed, takes are capped at 60 s and cropped to a 400×400 mp4
  (`testExportRoundClipCropsToSquare`). The simulator has no camera —
  `AVCaptureDevice` returns nil and the strip answers «Видео не записано:
  камера недоступна»; capture itself ran on the owner's device.
- **The chain.** roundpeer tapped the circle; when it finished, the voice
  message above started on its own, and the chain stops at heard or outgoing
  notes (`RoundVideoTests` chain cases).
- **Listened receipts.** Starting either note marked it locally
  (`listenedAt`) and sent an encrypted `listened` service frame; alfa's
  outgoing voice and circle both show a filled dot
  (`alfa-outgoing-dots-filled.png`), roundpeer's own unheard dots went out.
  Verified in both databases: `listenedBy` on alfa holds roundpeer's userId
  for seq 5 (roundVideo) and seq 6 (voice); `listenedAt` set on both rows at
  roundpeer. Group dot rules (two dots under 15 recipients, one above) are in
  the cell logic; the live run covered the direct-chat dot.

## Checks

- `swift test` (MsngrKit): green, including `RoundVideoKindTests`,
  `NoteListenedTests`.
- MsngrTests on the simulator: green, including `RoundVideoTests` (7 cases).
- Server untouched: kind, media and `listened` travel inside the encrypted
  payload; the service flag on the frame is set by the client.

## Found in passing

- The synthetic seed video had always decoded as green noise (BGRA frames
  written into NV12 buffers) — replaced with a bundled stock clip, c627fec.
- The play glyph could come back over a playing tile on any reconfigure
  (`syncProgressRings` unhides the glyphs it knows) — the autoplay path now
  removes the glyph instead of hiding it.

## Open

- The owner's device stutter report is answered by the fixes above but not
  yet confirmed on a Release build on the device.
