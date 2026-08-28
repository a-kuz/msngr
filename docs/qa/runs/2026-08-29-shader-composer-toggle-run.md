# The shader composer behind a switch — live run

2026-08-29, simulator `msngr-e1` (iPhone 17, DF64BC42), the `echo7b` account,
the chat with `delta7b`.

## The change

Settings → «Шейдеры» gains «Композер шейдеров в чатах»
(`ShaderSurfaces.composerEnabled`, off by default). The switch governs only
the two attachment-menu entries that send shader code as a message — «Shader»
and «Bubble shader»; writing a shader in place of a message is the owner's
debugging tool, not the everyday path. The sticker panel, the chat
background, the avatar and the effects keep their own composer entries
whatever the switch says, and a received shader message still renders, opens
in the player and shows its previews — none of those paths read the flag.

## What was seen

1. Switch off (the default): the attachment menu holds photo, file and
   sticker only — `chat.attach.shader` and `chat.attach.bubbleShader` are
   absent from the accessibility tree (`menu-off.png`).
2. The switch flips by hand in Settings (`settings.shaderComposer`, AX value
   0 → 1) and back in the same chat the menu grows both entries
   (`menu-on.png`).
3. With the switch off, the sticker panel's own «+» still opens the
   «Шейдер-стикер» composer (`sticker-composer.png`) — the act of writing a
   sticker is untouched.

## Checks

- `MsngrTests` pass (`scripts/build-slot.py xcodebuild … test
  -only-testing:MsngrTests`).
- The live run above; screenshots in `2026-08-29-shader-composer-toggle/`.
