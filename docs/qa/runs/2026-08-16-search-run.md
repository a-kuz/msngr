# Search on the chat list

One field over chats, message text and people. Chats are filtered in place on
every keystroke; message hits come from `messageFts` on a paged query, people
from the server. Tapping a message hit opens the chat on that message, however
deep it sits.

Screenshots — `2026-08-16-search/`. Run date: 2026-08-16.

## Stand

Two own simulators, iPhone 17, iOS 26.5, deleted after the run: `search-agent`
(3BC964F6) as `ivan_s` and `search-peer` (C5E205C8) as `irina_s`. Own `wrangler
dev` on :8817 with `--persist-to` in the session scratchpad and D1 migrations
applied into it; both apps launched with `MSNGR_SERVER=http://localhost:8817`.
Build from the working tree.

The chat between them holds 2006 messages: six written by hand, 2000 from the
DEBUG seeding button. Display names are Latin because the simulator's hardware
keyboard has no keycodes for Cyrillic; the Russian side of the tokenizer is
covered by `MessageSearchTests` instead.

## Run

| Step | Expectation | Fact |
|------|-------------|------|
| type `irina`, screenshot at once | chats already on screen, messages still being searched | chat row plus «Ищем в переписке…» (`01`) |
| the same query a moment later | messages and people below the chats | three hits with `Irina` highlighted, newest first, and `@irina_s` under «Люди» (`02`) |
| type `tickets` (no chat carries the word) | full-text result and nothing else, no empty screen in between | two hits, incoming and outgoing (`03`) |
| tap the older hit | the chat opens on that message | message 2000 rows deep, feed anchored on it, way down to the newest intact (`04`) |
| type `test message` (2000 hits), scroll | pages arrive as the reader goes | walked from `1000 of 1000` down to `714` without a repeat or a hole (`05`) |
| search `tickets` on the peer before the request is accepted | the request keeps its content | «Ничего не нашлось» (`06`) |

The messages of a pending request are already in the peer's database — the
search query is what keeps them out of the result.

## Jump to a message deeper than the window

Paging the window up one screen at a time reached 12 pages and gave up, so a hit
2000 messages back opened the chat at its bottom and stayed there. `ensureLoaded`
now moves the window floor straight onto the message and stretches the window's
capacity to the newest message, so the jump costs one read and the reader keeps
the way down. Pages are still walked when there is nothing to move onto: no seq,
or no row on this device yet.

## Not covered here

Media, files and links are not sections of this search. The gallery pages one
chat at a time (`ChatGallery`), and a list-wide media section would need a merge
across chats that nothing else asks for yet.

Search inside one chat is not wired to a screen. Its query layer is the same
one: `MessageSearch.page(_:query:chatId:)` takes a chat and is covered by
`testScopedToOneChat`.
