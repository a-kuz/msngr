# The chat list, all eight items of it, driven by hand

Run date: 2026-08-16. No screenshots kept.

## Stand

Own simulators `chatlist-a` (B5BE76FC) and `chatlist-b` (C4480C18), both iPhone
17 on iOS 26.5, deleted after the run. Own `wrangler dev` on :8812 with
`--persist-to .wrangler-chatlist` in the working tree and D1 migrations applied
into it; both apps launched with `MSNGR_SERVER=http://localhost:8812`. Two real
accounts with real keys, `anna` («Anna Kim») on A and `boris` («Boris Petrov»)
on B, so every message in this run was encrypted on one device and opened on the
other. A third account, `dmitry_v` («Dmitry Volkov»), was registered straight
through the API to raise a second chat request; it has fake keys and never sent
anything.

The list on A ended up as: a request from Dmitry, an archive section with one
chat, the group «Work» (pinned, unread), the group «Sport» (pinned, muted,
unread), the group «Family» (archived) and the direct chat with Boris. Both
devices were driven with `idb`, and every UI text below is what the
accessibility tree returned.

The simulator keyboard types Latin only under `idb`, so names and messages are
in English. One of them arrived as «Dinneunday» instead of «Dinner on Sunday» —
that is the injector dropping characters, not the app.

## What the eight items turned out to be

| Item | Fact |
|------|------|
| 64, «печатает…» in the preview | Shows in place of the preview while the peer types, in a direct chat and in a group. Goes out five seconds after the last keystroke with no message involved, and within a second if the peer empties the field. Held the row for the whole five seconds after the peer sent — see below. |
| 65, «Черновик: …» | Appears when the chat is left with text in the field, red label plus the text. Reopening puts the text back into the field; clearing the field and leaving takes the label away. Typing outranks it: while Boris typed the row read «печатает…», and the draft line came back when he stopped. |
| 66, the mute icon and the pin | The mute icon sits after the title, the pin in the badge's place, and unread pushes the pin out: «Sport» muted showed a grey badge, «Work» an accent one. |
| 67, sorting | Pinned on top, the rest by activity. Pinned «Work» at 18:44 stood above unpinned «Sport» at 18:45; with both pinned, «Sport» went over «Work» on a new message; the unpinned direct chat with the newest message of all (19:02) stayed under both. |
| 68, swipes | Left: «Закрепить» / «Открепить». Right: «Архив», «Без звука» / «Вкл. звук», «Удалить» with a confirmation. Each one changed the row and reached the server (`POST /api/chats/<id>/flags` in the stand log). |
| 69, the archive | The section row with a counter sits under the requests, the screen opens, «Из архива» puts the chat back in the list. A tap on an archived chat opened nothing at all — see below. |
| 70, the requests section | «Заявки на переписку» above everything else, «Новая заявка» instead of a preview, no badge and no ticks. «Принять» turned the row into an ordinary chat with the decrypted text and the unread badge; «Заблокировать» took the chat away and blocked the sender (`POST /api/chats/direct:…/delete`, `POST /api/block`). |
| 71 | The same requests section; 70 and 71 are one feature in two ROADMAP lines. |

## The typing line covered the message it had announced

Boris typed, A's row read «печатает…», Boris sent, and for the next five seconds
the row went on saying «печатает…» while the message was already in the database,
in the banner and in the unread count. Reproduced in the direct chat and in the
group.

The composer empties its field from code after a send, and `UITextView` raises no
delegate callback for that, so `textChanged` never ran and no typing stop went
out; the receiver was left waiting for its own five-second timer. The send now
says so itself, and, because a stop frame can be late or lost anyway, an incoming
message takes down its sender's typing on the receiving side as well. After the
fix the row read «Second ping» one second after the send, with «печатает…»
confirmed on the row a second before it.

The chat list's own typing refresh only walked the active chats, so an archived
row could keep a typing line until some other database write came along. It walks
the archive too now: Boris typing in the archived «Family» lit the row in the
archive screen and the preview came back five seconds later.

## The archive was a dead end

A tap on an archived chat pushed nothing. Four taps in a row pushed nothing, and
then a tap on «Назад» produced the chat — four times over, one per queued tap,
each stacked on top of the archive.

The archive was opened by a `NavigationLink` carrying its own destination, inside
a stack whose other destination is driven by `NavigationPath`. The archive is a
route on that same path now, and one tap opens the chat, «Назад» returns to the
archive and the next one to the list.

Two more things on that screen: the rows were drawn as plain navigation links,
with the system chevron and their own insets while the chat list hides both, and
emptying the archive left a blank screen. The rows go through the same `ChatRow`
as the list now, and an empty archive says «В архиве пусто».

A request row had a full swipe, so the same drag that switches a folder tab would
have blocked a stranger and taken the chat away for good. Off now, like every
other row in the list.

## Gaps

Notifications say nothing here: the APNs mock was not running on this stand, so
the run only shows what the socket delivers.

Typing in a group shows «печатает…» with no name. The spec asks for a name in the
chat header, not in the list, so this is what it should say — but nobody has
looked at a group where two people type at once.

The delete confirmation comes up as a popover anchored near the top of the list,
with «Покинуть» alone and cancel by a tap outside; that is `confirmationDialog`
choosing its presentation, and it was not touched.

The unread on «Work» stood at 1 before a rebuild and reinstall and at 0 after.
Two more attempts — a restart and a reinstall of the same build — both kept the
number, and the cause was not found. Leaving it written down rather than
explained.

Found while setting the run up, outside the chat list and not fixed: a row in
«Новый чат» only reacts to a tap on the avatar or the name. The `Spacer` between
the name and the right edge takes no hits, so half the row is dead.

## Checked with

`make check DEV_UDID=74B78AFC` (gate-runner), the UI tests and the smoke against
the stands the Makefile picks: :8787 for the UI tests, the smoke's own throwaway
stand for the server.
