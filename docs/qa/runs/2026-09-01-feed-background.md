# A background for the feed — live run

2026-09-01, simulator fable-a (carduser), the shared stand.

## Scenario

1. Settings → «Фон чата» in the appearance section opens the picker for every
   chat: «Без фона», the gallery set (Aurora, Dusk, Paper) with live shader
   previews, and «Своё фото» (`2026-09-01-background-picker.png`).
2. Picked Dusk. The chat with Peer User draws the Dusk shader as its
   background (`2026-09-01-background-dusk.png`) — the global choice reaches a
   chat with no choice of its own.
3. The chat's card → «Фон чата…» opens the same picker for this one chat;
   «Своё фото» opens the photo library, and the picked waterfall becomes this
   chat's background over the global Dusk
   (`2026-09-01-background-photo.png`, the picker with the photo card selected
   in `2026-09-01-background-picker-photo.png`).

## What it is made of

- `FeedBackground` — a shader or a picture file; per-chat values and the
  global one live in `kv` under the existing background prefix, pictures as
  files in the container's `backgrounds` folder. A picture no key references
  any more loses its file.
- The chat screen draws the chat's own choice or the global one; a shader
  runs as before, a picture draws as a static fill.
- The shader composer path («Шейдер-фон…») and «Set as background» in a
  shader message's menu keep working over the same storage.
- The gallery grew two quiet backgrounds, Dusk and Paper, both dark-mode
  aware; every gallery shader still compiles (ShaderGalleryTests, 573 core
  tests green).

One stumble fixed along the way: the picker's sheet hung off a `Section`,
where the modifier lands on every row — presenting it dismissed the settings
sheet instead. Moved to the screen's root, as the other sheets do.
