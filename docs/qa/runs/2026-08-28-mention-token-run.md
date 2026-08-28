# Mentions: the token, its rendering and the tap

Date: 2026-08-28. Simulator: solo-live (165449DB-8D23-4128-B3B0-63D26B8B00C2),
shared stand :8787, fixture alfa3; sender bravo3 via `msngrfixture send` with a
token in the text.

## What was delivered

- The mention lives in the message source as `[@Name](user:<userId>)`, the way
  the rest of the markup does: nothing is stored outside the text, the id
  survives any rename, an edit carries it like any other characters.
- The parser turns the token into a `.mention` span with a `user:` link; the
  bubble renders it in the accent colour and a tap opens (or creates) the
  direct chat with that person through `DirectChat.open`.
- Previews never show the raw token: the chat list row, the reply quote
  (`previewText`) and notification bodies all go through
  `MessageMarkdown.mentionsStripped`, which leaves the visible `@Name`.

## Verified

- `swift test --filter "MentionMarkdownTests|MarkdownTests"` — 33/33: the span,
  mention inside bold, broken tokens staying plain text, no re-linkify, the
  strip.
- Live: bravo sent «Спроси [@Charlie Service](user:…) про демо» — the bubble
  shows «Спроси @Charlie Service про демо» with the mention in accent colour;
  the tap opened the direct chat with Charlie Service; the chat list row shows
  the stripped text.

## Left for the next slices

- Composer autocomplete on `@` (the token is currently written by hand or by
  the fixture).
- Your own mention marked in the feed and the chat list, piercing mute the way
  a reply already does; the unread-mention counter and the jump.
