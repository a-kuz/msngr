# Chat-list search on a 20 000-message chat

A second run over the search built in `2026-08-16-search-run.md`, this time at
the size the spec asks for: one conversation of 20 000 messages. Run date:
2026-08-16.

## Stand

Own `wrangler dev` on :8863 with its own `--persist-to` in the session
scratchpad, D1 migrations applied into it, `APNS_HOST` pointed at an unused
port. Two own simulators, iPhone 17, iOS 26.5, deleted after the run:
`search-verify` (4CCBC870) as `ivan_s`, `search-peer` (118467CE) as `irina_s`.
Both apps launched with `MSNGR_SERVER=http://localhost:8863`. Build from the
working tree.

Text went into the fields through the pasteboard: on this host the simulator
maps hardware key codes through a Russian layout, so typed Latin arrives as
Cyrillic. Digits are unaffected, and the queries that had to be typed key by key
used them.

The direct chat holds 20 004 messages: four written by hand, 20 000 from the
DEBUG seeding button, which sends through the regular path. Seeding took
6 min 16 s, about 53 messages a second. A group chat with one message was added
later to have hits from two conversations at once.

## Run

| Step | Expectation | Fact |
|------|-------------|------|
| `tickets` on the peer while the request is unaccepted | the request keeps its content | «Ничего не нашлось» |
| accept, then `tickets` again | the message that arrived before acceptance is findable | one hit, the message sent 20 minutes earlier |
| `irina` | chats, messages and people in one list | all three sections, the match in the snippet in accent colour |
| `Ирина` in Cyrillic | full text only, no chat name matches it | one message hit, no other section |
| `Test message` over 20 000 | the instant half does not wait for the slow one | «Ищем в переписке…» on screen at 0.36 s, still there at 1.05 s, rows at 1.22 s |
| the same result, scrolled | pages arrive as the reader goes | walked 20000 → 19377, every sample continuous and overlapping its neighbour, no repeat and no hole |
| `1234` | the word being typed already matches | 1234 and 12340–12349, newest first |
| `saturday` | hits from different chats in one order | 11:52 from the group, 11:49 and 11:19 from the direct chat, each row with its own chat |
| tap `Test message 500 of 20000` | the chat opens on that message | opened on it with 491–509 around it, the way down intact |
| tap a person | the direct chat opens | the existing chat with Irina |

Ranking is time, newest first, both inside one chat and across chats.

## Numbers

- First page over 20 000 messages: 1.2 s from the query landing to rows on
  screen, of which 0.18 s is the debounce.
- Opening the chat at the bottom: 0.7 s. Opening it on message 500 of 20 000:
  4.9 s.
- Resident memory of the app: 230 MB at the bottom of that chat, 320 MB after
  the jump to message 500.

## The cost of the jump

`ensureLoaded` puts the window floor on the message and stretches the window's
capacity to the newest message, so everything between the two is in the feed.
For a message 19 500 rows back that is 19 500 rows: the 4.9 s and the 90 MB
above. The jump lands and the reader keeps the way down, which is what the
feature needs; the price grows with the distance from the end of the
conversation, and nothing bounds it today.

## Tests added

`MsngrTests/ChatSearchModelTests` covers what the run can only watch from
outside: an answer for an older prefix arriving after a fresher query has
landed, for messages and for people; the letters of one word costing one query;
an empty list before the first page not being read as "nothing found"; clearing
the field clearing the result. The model now takes its two sources as
parameters, which is what makes those cases writable.

Both cancellation cases were checked against a deliberately broken guard: with
the generation check removed each fails with the older prefix's answer on
screen.

## Not covered here

No pushes: the run had no APNs mock, and search does not go through
notifications.

The peer only searched to prove the request case, so nothing here says how the
receiving side behaves on a large chat.

Media, files and links are still not sections of this search, for the reason
given in the spec.
