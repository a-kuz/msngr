# The shader showcase

A two-minute demo of shaders as the product's format for stickers, effects,
backgrounds and avatars, run inside the app on a phone in the hand. Nothing in
it is a mock-up: every surface is the shipped code, the accounts are on the
shared stand, and every message is end-to-end encrypted.

## What is in the set

`ShaderGallery` in MsngrCore (`ios/MsngrKit/Sources/MsngrCore/ShaderGallery.swift`),
one document per surface; `ShaderGalleryTests` compiles every pass through the
transpiler and the Metal compiler.

| Surface | Shader | What it does in the hand |
|---|---|---|
| Sticker | Pond | a round pond; a finger is a drop, rain falls on its own |
| Sticker | Fireworks | a tap launches a rocket toward the finger; one goes up by itself every few seconds |
| Sticker | Eye | follows the finger, the pupil widens under it, a tap makes it blink |
| Sticker | Ink | ink in water, stirred by the finger; a thread rises by itself; the ink is the accent colour |
| Sticker | Clock | the real time from the phone's clock; face and marks in the theme's colours |
| Sticker | Heart, Sparkle | the bundled pair: a raymarched heart that beats and hums on a tap, the sparkle plate that orbits under the finger |
| Background | Aurora | night sky over mountains; leans with the phone's tilt; a pale dawn in the light theme |
| Bubble | Foil | holographic foil behind a text; the bands shift as the bubble moves up the screen |
| Bubble | Ember | slow fire behind a text, sparks rising |
| Avatar | Nebula | Nova's avatar: the cloud in the disc, a halo breathing past the circle, a comet orbiting it |
| Avatar | Orbit | the «Showcase» group's avatar: a planet whose moons leave the circle and cross the interface |
| Effect | Send burst, Reaction burst | the bundled effects: sparks out of the send button, confetti on a reaction |

Every sticker in the set is in the bundled pack (`ShaderStickers.bundled`), so
the presenter's own pack has them and can send any of them back.

## Putting it on a phone or a simulator

The stand holds three accounts made for this: `demo` (the presenter), `nova`
(sends the stickers, wears the Nebula avatar) and `iris` (holds the «Showcase»
group). Their homes are under `.claude/fixtures/`. To build or refresh them:

```bash
cd ios/MsngrKit && swift build --product msngrfixture
.build/debug/msngrfixture showcase --dir ../../.claude/fixtures --base https://msngr.a-kuz.online
```

The command registers the accounts when they are new, dresses the chats and
sets the avatars, and adds nothing to a chat that is already dressed, so it is
safe to run again. Then hand `demo` to a simulator:

```bash
scripts/fixture.py install demo <udid> --launch
```

A home belongs to one device at a time: `pull` it back before installing it
elsewhere, and never run `msngrfixture` as `demo` while a device holds that
home.

## The script

1. **The chat list.** Nova's avatar is turning: a nebula with a comet
   circling outside its circle; the «Showcase» group's moons leave the
   avatar and cross the row. Say: an avatar is a program, a hundred lines,
   drawn live on the phone — and it is not boxed into its circle.
2. **Open Nova.** The aurora is behind the feed. On a phone, tilt it left and
   right: the sky leans. Switch the appearance in Control Centre and come
   back: the same shader is a dawn in the light theme.
3. **The stickers.** Scroll to the top of the conversation and go down:
   - Pond: touch the water, hold and drag; watch the rain when you let go.
   - Fireworks: tap twice in different places.
   - Eye: move a finger around it, then tap.
   - Ink: stir with a finger; note it is the app's accent colour, and that a
     different accent gives a different ink.
   - Clock: it is the real time.
   Say: a sticker travels inline in the message, encrypted with it; the
   receiver's phone compiles and runs it. No server ever sees it.
4. **The bubbles.** Scroll the two foil and ember texts up and down: the foil
   tilts with the bubble's place on the screen.
5. **Send one back.** The sticker button opens the pack; tap the heart. It
   lands in the feed and beats when tapped; on a phone the beat is in the
   haptics. The send itself fires the burst out of the button.
6. **React.** Long-press the foil text: the lifted bubble keeps its shader
   running (the overlay lays a live canvas over the snapshot). Pick a
   reaction: confetti out of the bubble.
7. **The budget.** With the aurora, five stickers and a foil on one screen,
   four animate and the rest hold a frame; scroll and the slots move to what
   just came in. Say: this is what keeps it at 60 fps on the slowest phone we
   ship to.

## What needs a phone

The simulator has no tilt, no haptics and no real sensors: the aurora stands
still, the heart's beat is silent. Everything else in the script is seen on a
simulator. Fast on the simulator proves nothing about the frame cost; a phone
does.

## Resetting

`msngrfixture showcase --dir … --base …` adds only what is missing. For a clean
conversation, delete the three homes under `.claude/fixtures/` and run it
again: it registers three new accounts under free handles.
