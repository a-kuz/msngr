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

## The wash under the bubble (seventh slice)

- An incoming message carrying your mention keeps an accent wash under its
  bubble for as long as it is on screen: the layout plan decides
  (`mentionsMe`), the cell lays a tinted view under every other subview, so a
  photo covers it and only the bubble background is tinted.
- MentionWashTests, 6/6: incoming mention of you, a mention of a neighbouring
  id (`u12` against `u1`), plain text, your own message, a deleted message,
  and an empty own id before bootstrap. MsngrTests as a whole 39/39.
- Live in «Design»: «Финал: @Alfa, первый» and «Wash check: @Alfa Service look
  here» sit on the warm tint while «и снова обычная строка» between them stays
  white.

## «@все» (eighth slice)

- The group-wide token `[@все](user:all)` addresses every member:
  `mentionsUser` answers true for any id, so the mute-piercing, the chat-row
  mark, the unread counter and the bubble wash all light up through the code
  the personal mention already runs. Its tap leads nowhere — `user:all` names
  no person. Only a group admin is offered «все» in the autocomplete
  (`ChatPermissions.canMentionAll`); the handle resolves through the regular
  tokenizer.
- Units: ChatSettingsTests `testMentionAllOnlyForAGroupAdmin`,
  MentionMarkdownTests `testTheGroupWideTokenMentionsEverybody` (an id merely
  starting with "all" does not match), MentionMarksTests
  `testTheGroupWideMentionLightsTheMark` — 26/26 with the neighbours.
- Live on the server stand (see below): bravo sent «Собрание в 15:00, @все»
  into the muted «Design» — the row lit «@» next to the badge, the bubble sits
  on the accent wash, the token renders as a link and its tap stays in the
  chat. Alfa (admin in «Design») got «все» as the first capsule of the panel
  over the draft «@», the tap put «@all» into the field and send resolved it
  to `[@все](user:all)` (watched in the device database, status sent). In
  «Standup», where alfa is a member, the same draft offered only Bravo and
  Charlie.
- The run doubled as the first live pass over the relocated shared stand: the
  message travelled laptop CLI → https://msngr.a-kuz.online → adad worker →
  alfa's socket.

## Left for the next slices

- A mention survives the author's rename (the token already carries the
  userId; not yet watched live).
