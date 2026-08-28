# Shader messages

Owner's request, 2026-08-28: send a visualization written as user code, in the
Shadertoy dialect of GLSL (`mainImage(out vec4 O, in vec2 F)`, `iTime`,
`iResolution`), and have it render live in the peer's feed. The owner's
sample is a 44-second MacWrite/MacPaint animation of ~300 lines with constant
arrays, `switch`, `inverse(mat2)`, `mod`, `.length()` on arrays, and integer
bit operations. Customization beyond sending (a shader as the chat background,
a shader behind a text bubble, a shader avatar) is written into the ROADMAP,
not built here.

The code map gathered before this design is `docs/research/shader-messages-codemap.md`.

## Running user GLSL on iOS

Metal is the only GPU API on the platform and it compiles MSL, not GLSL. Three
ways to bridge that were weighed:

1. A textual transpiler from the Shadertoy dialect to MSL plus a shim header,
   compiled on the device with `MTLDevice.makeLibrary(source:options:)`.
   Chosen. GLSL ES and MSL are near-identical in syntax; the differences are a
   type rename (`vec2` → `float2`, `mat2` → `float2x2`, `ivec2` → `int2`),
   array constructors (`int[](…)` → `{…}`), `.length()` on arrays, `out` /
   `inout` parameters (`thread T&`), and a set of library functions MSL lacks
   or spells differently (`mod`, `inverse`, `atan(y, x)`, `radians`,
   `inversesqrt`, `dFdx`, the scalar-broadcast overloads of `clamp`, `min`,
   `max`, `smoothstep`, `step`, `mix`). No dependency, a few hundred lines of
   Swift, and the owner's sample is covered whole.
2. glslang + SPIRV-Cross compiled for iOS. A real GLSL front end, but two
   C++ libraries of tens of megabytes, a custom build for device and
   simulator inside xcodegen, and the MSL still has to be compiled at
   runtime. Kept as the fallback if the textual approach hits a wall.
3. Accept MSL only. No translation, but the owner's scenario is Shadertoy
   code, so this does not serve it.

### The transpiler

`ShaderTranspiler` in MsngrCore, pure text in → MSL out, no Metal import, so
it is unit-tested on the host.

- Strip comments and `#version` / `precision` lines. Rename the types. Rename
  identifiers that are C++/MSL keywords but legal GLSL identifiers (`half`,
  `kernel`, `constant`, `device`, `thread`, `texture`, `sampler`, `template`,
  `class`, `this`, `new`, `char`, `short`, `long`, `unsigned`, `static`, …)
  by appending an underscore.
- Rewrite `T[](…)` and `T[N](…)` constructors into brace lists.
  `NAME.length()` becomes `(int)(sizeof(NAME)/sizeof(NAME[0]))`.
- In parameter lists, `out T x` and `inout T x` become `thread T& x`, `in T x`
  becomes `T x`.
- Program-scope `const` declarations of builtin types (scalars, vectors,
  matrices, and arrays of them) are hoisted above the wrapper struct as
  `constant` globals, so a lookup table costs no per-thread copy.
- Everything else at program scope — functions, `struct` definitions,
  non-const globals — goes inside `struct ShaderToy { … }`, whose data
  members are the Shadertoy uniforms (`iTime`, `iTimeDelta`, `iFrame`,
  `iResolution`, `iMouse`, `iDate`). A member function sees the uniforms
  from anywhere, member functions may call each other in any order, and a
  mutable GLSL global becomes a plain data member.
- The shim header supplies the missing library functions as free functions;
  a user function of the same name shadows it inside the struct.
- The emitted fragment function flips `y` so `F` has its origin at the
  bottom-left, as Shadertoy does, constructs the struct from a uniform
  buffer, and calls `mainImage`.

Uniforms in v1: `iTime`, `iTimeDelta`, `iFrame`, `iResolution`, `iMouse`
(from touches in the full-screen player, zero in the feed), `iDate`. No
`iChannelN` textures and no multipass; a reference to one is a compile error
the sender sees before sending.

### Compiling and running

`ShaderProgram` (app side, Metal) compiles the MSL on a background queue and
caches the `MTLRenderPipelineState` by a hash of the source, so a shader seen
twice in the feed compiles once. The source is capped at 64 KB and the
compile at a wall-clock timeout; both a failed compile and a command buffer
that ends in an error put the shader into a failed state that stays for the
lifetime of the process. Compilation is Apple's compiler in its own sandbox;
what user code can do is burn GPU time, and the OS already kills a command
buffer that overruns, which the error path above turns into the failed state
rather than a retry loop.

## The message

`kind: "shader"` with a new optional field `ContentPayload.shader` holding
`source` and `lang` (`"glsl-st"`, the Shadertoy dialect). The source is not
put in `text`, so search, the reply quote and the chat list never treat it as
prose. `MessageKind` gains `case shader`; the `Message` row carries the
source in a new `shader` column of the same shape (the schema changes with no
migration, per `docs/PROCESS.md`). It is a normal content kind: it grows
unread and raises a push, and stays out of `SyncEngine.serviceKinds`. The
server is content-kind-blind and does not change. A typical source is above
the 4 KB APNs ceiling, so the push travels without the envelope and the
message arrives on the next connection, which is the existing behaviour for
oversized content.

## The feed

The bubble is the width of a photo bubble at a 16:9 aspect; the plan gets a
`shaderFrame` and `BubbleLayout.compute` a `case .shader`. `MessageCell`
places a `ShaderMessageView` (an `MTKView` under a thin status layer) in that
frame, the same way `voiceFrame` hosts `VoiceMessageView`. The view renders
only while its cell is on screen, at 30 fps and half the drawable scale in
the feed, and stops in `prepareForReuse` and when the controller disappears.
While the program compiles the view shows the bubble background; a failed
program shows «Не удалось отобразить» (a state, not a cause) and keeps the
source reachable.

A tap opens `ShaderPlayerScreen`: full screen, 60 fps, full scale, `iMouse`
from touches, a pause button, the elapsed time, and a «Source» button that
shows the code with a copy action.

## The composer

A «Shader» item in the attachment menu opens `ShaderComposerScreen`: the live
preview on top, a monospaced editor below, a «Paste» button, and the
compiler's first error line under the preview. The preview recompiles after a
0.4 s pause in typing. «Send» is enabled only when the program compiled, and
sends `ContentPayload(kind: "shader", shader: …)` through the simple
`enqueue` route.

## Previews and strings

Chat list row, push banner (`NotificationContent.preview`), reply quote
(`ChatViewModel.previewText`) and search icon show a localized «Shader» with
the `cpu` glyph. Strings go into both catalogs (the NSE reads the core one).
`docs/protocol.md` lists the new kind and the `shader` field.

## Not in this change (ROADMAP)

A shader as the chat background, «Set as background» from a received shader
message, a shader behind a text bubble, a shader avatar, `iChannel` textures
and multipass buffers, a shader picker / gallery.

## Verification

- `swift test` in MsngrKit: the owner's sample and a set of small dialect
  probes (`out` params, array constructors, `.length()`, `mod` on negatives,
  `inverse`, keyword renames) transpile, and the emitted MSL compiles with the
  host's Metal device in the test (`MTLCreateSystemDefaultDevice`, skipped
  where none exists).
- MsngrTests: the plan for a shader message, the chat list preview, the
  reply quote.
- A live run on the simulator: alfa composes the sample from the clipboard,
  the preview animates, sends; bravo receives, the bubble animates in the
  feed, the player opens, the chat list says «Shader». Report in `docs/qa/runs/`.
- `make check` in the background after the merge.
