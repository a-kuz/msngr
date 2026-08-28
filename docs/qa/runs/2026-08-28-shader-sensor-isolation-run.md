# A peer's shader document reads no sensor — live run

2026-08-28, simulator `msngr-7b` (iPhone 17, E26DA55C), the shared stand at
`https://msngr.a-kuz.online`.

## The change

`ShaderRenderer` takes a `deviceInputs` flag. With it off, the renderer holds
no `DeviceInputs` feed, the sensor slots of the uniform block stay zero
(`iAttitude` is the identity quaternion) and a live channel (camera,
microphone, keyboard) reads as the empty texture. Time, touch, the palette and
the haptics output are unaffected.

Who gets the flag:

- on: the full-screen player, the composer preview, the chat background, the
  bubble-shader strip over the input field, the background preview in the chat
  info, the sticker panel, the effect canvases, an outgoing bubble shader, a
  sticker that is in the user's own pack (`ShaderSurfaces.hasSticker`);
- off: a shader message in the feed, an incoming bubble shader, a sticker not
  in the pack, every avatar canvas (the chat list and the feed default to off).

`DeviceInputs.retain`/`release` now log `device feed on:`/`off:` at info level
in the `shader` category, which is what this run reads.

## The scenario

Two fresh accounts registered through `msngrfixture` (`delta7b`, `echo7b`),
their homes under `.claude/fixtures/`; the fixture trio was left alone because
alfa's sync on the shared stand is wedged by the repair backlog (reported to
the coordinator, tracked separately). The `delta7b` home was handed to the
simulator; `echo7b` sent it the same document twice — as a shader message and
as a sticker — with `msngrfixture send --shader <file> --kind shader|sticker`
(added in this change). The document reads the back camera as `iChannel0`,
`iLocation` and `iGyro`.

## What was seen

1. The feed with both incoming documents on screen: both canvases compile and
   render (`shader starts` at 23:28:14), no permission prompt, and no
   `device feed on` line.
2. A tap on the shader message opens the player: at 23:28:16 the log says
   `device feed on: motion`, `location`, `camera(front: false)`, and the
   system camera prompt appears over the player — the first moment the
   document is allowed to reach the device.
3. Closing the player at 23:28:22: `device feed off` for all three.

The black picture inside the bubbles is the document's own doing (it paints
the camera channel, which is the empty texture in the feed), not a failed
compile: both passes log `Compilation SUCCESS` and `shader starts`.

## Checks

- The app builds and `MsngrTests` pass (`scripts/build-slot.py xcodebuild …
  test -only-testing:MsngrTests`).
- The live log above, `log show --info --predicate 'category == "shader"'`.
