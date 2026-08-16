# Search inside one chat

The magnifier in the chat header, the matches over the feed, the walk through
them and the way back. The query layer is the one the chat list already uses:
`MessageSearch.page(_:query:chatId:)` scoped to this chat, plus a new
`MessageSearch.count` for the size of the result. Run date: 2026-08-16.

## Stand

Own `wrangler dev` on :8901 with its own `--persist-to` in the session
scratchpad and D1 migrations applied into it. Two own simulators, iPhone 17,
iOS 26.5, deleted after the run: `chatsearch-agent` (304B6A26) as `ivan_cs`,
`chatsearch-peer` (8058AE8A) as `irina_cs`. Both apps launched with
`MSNGR_SERVER=http://localhost:8901`. Build from the working tree.

The direct chat holds 20 005 messages: five written by hand, 20 000 from the
DEBUG seeding button, which sends through the regular path. Seeding took
5 min 30 s, about 60 messages a second. One round of attachments was added later
to have a hit that is a photo rather than a message.

Both simulators were switched to en-US: on this host the hardware keyboard maps
Latin through a Russian layout otherwise. The Russian side of the tokenizer is
covered by `MessageSearchTests`.

## Run

| Step | Expectation | Fact |
|------|-------------|------|
| tap the magnifier | the field takes the header and the keyboard comes up with it | field, «Отмена», the feed untouched behind them, the bar below reading «Поиск по этому чату» |
| type `tickets` | the matches cover the feed, newest first | three rows: the peer's 14:04, then the two of 14:03, the word in accent colour in each |
| tap the oldest of them | the chat shows that message, 20 000 rows back | on screen in 2.3 s, «История начинается здесь» above it, the bar reading «3 из 3» |
| ↓ then ↓ then ↑ | a step between matches costs nothing | 0.29 s, 0.22 s, 0.25 s, each landing on the message |
| tap the position | the matches come back | the list again, the place kept |
| «Отмена» | the feed returns to where the reader opened search | the newest message, 0.26 s, the input field back |
| scroll ten screens back, search `Booked`, open the hit, «Отмена» | the reader comes back to what they were reading, not to the end | back on message 18 968, the one at the top of the screen when search opened |
| type `zebra` | nothing found says so | «Ничего не нашлось» with «В этом чате нет сообщений с таким текстом» |
| type `message` (every seeded message matches) | the size of the whole result, not of the page read | «Ищем в переписке…» for 0.6 s, then «20,000 совпадений» |
| ↑ thirty times over that result | the walk crosses the page boundary on its own | «30 из 20,000», the feed on message 19 971 |
| search `Photo` after seeding attachments | an attachment caption is text like any other, and the row says it is a photo | one row with the photo glyph, «1 совпадение»; opening it lands on the image |

A message request keeps its content out of search: the card has no magnifier at
all. Checked on the peer before it accepted, in the pass where the field still
sat in the toolbar; the button and the field both live in the branch the request
card replaces, and that branch did not change afterwards.

## How it feels

The two costs are far apart. A match already in the feed window is a scroll and
nothing else: the steps above are a quarter of a second each, and walking thirty
matches in a row never stalls. A match deeper than the window makes the feed load
the history between it and the end — the cost `run-perfdb` is measuring — and
that is the 2.3 s above for a message 20 000 rows back.

So the screen spends it as rarely as it can. Typing and reading the list move
nothing. The jump happens when a match is chosen, and only if it is not already
in the window. Stepping between neighbouring matches inside the loaded history is
free, because the history the first jump pulled in is still there. Leaving search
fetches nothing at all: the window only ever grew, so the message the reader came
from is still in it, and «Отмена» is a scroll — and if search moved nothing, it
does not even scroll.

## The count

`MessageSearch.count` is what the bar needs to say «30 из 20 000», and joined to
`messageFts` the way the page is, it took 19.6 s on that chat: with no `LIMIT` to
stop it the planner walks the messages and asks the index about each one. Reading
the matching rowids out of a subquery instead makes the same count 9 ms
(`swift test`, in-memory database of 20 000 messages, debug build). Live on the
simulator the number now lands in about half a second after the last keystroke,
against ten seconds before the change.

Until it lands the bar says «Ищем в переписке…» rather than naming the page that
has been read: with 24 hits in hand and the count still running it said
«24 совпадения» for a second on a result of 20 000.

## What the run found and the branch fixed

- Opening search left the field without the keyboard. `@FocusState` does not
  reach a text field hosted by the navigation bar; the field moved into the
  screen as its own header row, with the navigation bar hidden behind it.
- The count above, both its cost and what the bar said while it ran.

## Tests added

`MsngrTests/ChatSearchSessionTests` covers the place in the result: the steps in
both directions, a step past the page that has been read waiting for the next
one, the count keeping the step alive beyond it, a new query forgetting the old
place, an empty list before the first page not being read as "nothing found",
and the bar not naming the page as the result while the count runs.
`MessageSearchTests` counts what the pages would deliver, and asserts the count
over a 20 000-message chat stays under a second.

## The gate

Green in parts, on the agent's own simulators and its own stand: `xcodegen`,
build, `swift test` (MsngrKit), MsngrTests, MsngrUITests, the server smoke
(`ALL PASS`), no fresh crashes.

The UI tests do not run against the shared stand on :8787 from this branch: it
answers `bad_keys` to registration, so every test stops at the first screen. The
same client registers on a stand raised from this branch (probe: the same
`/api/register` body is `bad_keys` on :8787 and accepted on :8901), so the two
sides of the API have drifted apart on the shared stand rather than in this
change. The suite was run against :8901 with the fixture user `akuz` created
there through `/api/register`.

Two runs before the green one failed on `chat.input` and the new-chat search
field not appearing inside their 8 and 5 second waits. The host was carrying a
load average of 370 at the time, and both screens opened by hand in seconds.

## Not covered here

No group chat: the author of a row falls back to the member list, and only the
two names of a direct chat were seen.

Nothing about the receiving side on a large chat: the peer was used for the
request case and for two incoming messages.
