# Shader messages, live run

2026-08-28, simulators `msngr-b5` (alfa) and `msngr-b5-b` (bravo3), iPhone 17,
iOS 26.5, the shared stand on :8787. Build from `a3df340` plus the fixes below.

## What was run

1. **A one-pass shader, sender to peer.** The owner's 300-line MacWrite /
   MacPaint sample (`ios/MsngrKit/Tests/MsngrCoreTests/Fixtures/macpaint.glsl`)
   on the clipboard, «+» → «Шейдер»: the composer picked the code up on
   opening, the preview animated inside a second, the verdict line read
   «Image» in green, «Отправить» became enabled. Sent to Bravo Service.
2. **The bubble in the feed.** The sender's own bubble animates in place at
   16:9 with the status capsule over the picture (`03:45` over the shader,
   `capsule.png`). On bravo the chat list row read «✨ Шейдер», and opening the
   chat showed the same animation running.
3. **A multipass Shadertoy export.** `flower-evening.shadertoy.json` (Image +
   Buffer A, the buffer reading its own previous frame) pasted into the
   composer in the Charlie chat: the verdict read «Buffer A · Image», the
   preview showed the path-traced glass converging, and the sent bubble
   carries the shader's name «flower evening» in its top left.
4. **The player.** A tap on that bubble opened the full-screen player: the
   accumulation ran on, the clock reached `0:09.9`, the controls (close,
   source, restart, pause) faded in on a tap.

Zero unreadable messages, no crash reports on either simulator, no
`shader failed` line in either device log.

## Defects found and fixed during the run

- **The bubble was a black rectangle.** The renderer took the pause out of the
  clock only when a first frame had already been drawn, so a canvas that was
  unpaused before its first frame stayed paused forever
  (`ShaderRenderer.setPaused`). A cell also only learned it was on screen from
  `willDisplay`, which arrives before `configure` installs the shader: the cell
  now remembers that flag (`MessageCell.onScreen`) and starts the shader when
  it is configured.
- **The status capsule sat under the shader.** The canvas was added on top of
  every bubble subview; it is now inserted below the capsule, so the time reads
  over the picture as it does on a photo.

## Checks

- `swift test` in MsngrKit: 415 tests, 0 failures, 5 skipped (the integration
  tests that need a stand of their own).
- `xcodebuild -scheme Msngr` for the simulator: green.
