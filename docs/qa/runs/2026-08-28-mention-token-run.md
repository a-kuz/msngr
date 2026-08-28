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

## Autocomplete (same day, second slice)

- The composer keeps a plain «@username» while typing; a suggestion panel with
  the chat's members appears above the field on an open «@prefix»
  (`mentionSuggestions`), a tap swaps the prefix for the handle, and send
  resolves every known handle into the token (`tokenizeMentions`, 6 unit
  cases: case-insensitive, mid-word @ untouched, unknown handle untouched,
  existing tokens pass through).
- Live in the «Design» group: the panel offered Bravo and Charlie over the
  draft «ask @», the tap made it «ask @charlie3», and the sent bubble shows
  «ask @Charlie Service» as a link. The draft was seeded through the database:
  the simulator's ru hardware layout transliterates `idb ui text`, so typing
  the prefix by HID is not reproducible here.
- Seen in passing, pre-existing: the Design fixture still shows one
  «Сообщение ещё не загружено» placeholder from an old repair gap.

## Mute-piercing (same day, third slice)

- A mention of you lifts the mute the way a reply to you already does: both
  notification paths feed `repliesToMe` with
  `replyTo.authorId == me || MessageMarkdown.mentionsUser(text, me)`.
  `mentionsUser` matches the exact id only (`u1` does not match `u12`) —
  MentionMarkdownTests, 7/7.
- Live: with the «Design» group muted, a plain message from bravo raised
  nothing; a message carrying [@Alfa](user:…) raised the banner.

## The tap on your own mention (owner's report, fourth slice)

- Tapping [@Alfa](user:<own id>) used to fall into `DirectChat.open(ownId)`;
  the server refuses a direct chat with yourself (`direct_needs_one_peer`),
  so the tap died silently. Now a mention of yourself opens the
  saved-messages chat; verified live in «Design». A mention of someone else
  still opens their direct chat.
- The earlier «tap opened the chat with Charlie» sighting was the chat list
  resorting between the screenshot and the scripted tap — the tap landed on
  another row; no product defect behind it.

## The «@» mark on the chat row (fifth slice)

- The chat list snapshot marks chats whose unread messages carry your mention
  (`MentionMarks.hasUnreadMention`: unread only, incoming only, deleted and
  foreign ids excluded — MentionMarksTests over an in-memory database), and
  the row shows an accent «@» circle next to the badge.
- Live: bravo's «Отметка: [@Alfa](…), проверь» into the muted «Design» lit
  «@ 1» on its row; a plain message to the direct chat showed the badge alone.

## The in-chat «@» button (sixth slice)

- `MentionMarks.unreadMentions` counts the unread mentions and names the
  earliest one; the chat screen shows an accent «@» button above the way-down
  button with the count, and its tap lands the feed on that message through
  the regular `MessageJump`. The counter follows the chat row, so reading past
  the mentions removes the button.
- Verifying it live surfaced the cursor defect below: the fixture chat kept
  `myReadUpTo = lastSeq` with dozens unread, so no mention ever counted as
  unread. Fixed first (see defects.md «An own service frame drags myReadUpTo
  over the peer's unread messages»), then the button verified live.

## Left for the next slices

- Your own mention marked in the feed and the chat list row; the
  unread-mention counter and the jump.
