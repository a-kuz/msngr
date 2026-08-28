# The half-scale shader setting — live run

2026-08-28, simulator `msngr-7b-scale` (iPhone 17, 99C6BEE3), the `delta7b`
account, the chat with `echo7b` holding an incoming shader message and an
incoming sticker.

## The change

Settings → «Шейдеры» gains «Половинное разрешение в чатах»
(`ShaderSurfaces.halfScale`, off by default). With it on, every canvas whose
priority is not `.focus` — the feed, the chat list, the backgrounds — sizes
its drawable at half the view's scale and the layer stretches it; the
full-screen player, the composer preview and the effect canvases stay at full
scale. Flipping the setting posts `ShaderSurfaces.scaleChanged`; a live canvas
re-lays out and a held canvas re-draws its frame at the new size.

## What was seen

The drawable sizes come from the renderer's `shader starts` line
(`log show --info --predicate 'category == "shader"'`).

1. Setting off, the chat with the two incoming documents:
   `540×540` (sticker) and `915×513` (shader message) — every pixel at @3x.
2. Setting on, the same chat reopened: `270×270` and `457×256` — exactly half.
3. Setting on, the shader message opened in the player: `1206×2622` — the
   full screen at full scale, the setting does not reach `.focus` canvases.
4. The toggle itself flips by hand and persists: the AX value went 1 → 0 → 1
   from taps on the switch (`settings.shaderHalfScale`), and the stored value
   survives a relaunch (`shaderHalfScale` in UserDefaults).

## Checks

- The app builds and `MsngrTests` pass (`scripts/build-slot.py xcodebuild …
  test -only-testing:MsngrTests`).
- The log lines above; the run drained the camera and location permission
  prompts the player had raised (the feed itself raised none, per
  qa/runs/2026-08-28-shader-sensor-isolation-run.md).

What this run does not say: anything about frame cost. The ROADMAP note
stands — only a device shows what half scale buys in frame time and thermal
state; this run shows the drawable sizes and the setting's reach.
