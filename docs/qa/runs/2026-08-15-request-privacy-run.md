# A conversation request: the contents stay hidden until it is accepted

Date: night of 2026-08-14 into 2026-08-15. Agent stand: simulators `msngr-req-a`
(06DB10FB, users `alice_rp1`, then `carol_rp1`) and `msngr-req-b` (80F10871,
users `bob_rp1`, `bob_rp2`), own `wrangler dev` on :8801 with a separate
`--persist-to`, own APNs mock on :9872. Simulators deleted after the run.

## What was checked

Before «Принять» is tapped, the receiver sees only the fact of the request and
the sender's profile. Text, media, previews and counters appear nowhere: not in
the chat feed, not in the chat list row, not in the in-app banner, not in the
badge. After acceptance the history already sitting in the local database opens
up in full.

## The request arrives

Alice sent Bob four messages. Bob's chat list shows a «Заявки на переписку»
section, and the row carries the name and «Новая заявка» in place of the text,
with no unread counter.

With the app in the foreground and the chat not open, the in-app banner at the
top carries the sender's name and the same placeholder instead of a preview.

The opened request has no feed at all: an avatar, the name, the username,
«хочет вам написать» and two buttons. There is no input field.

## Nothing leaks back to the author of the request

Bob opened the request and kept the screen open. At Alice all four messages
still had a single tick: neither delivered nor read arrived. Bob's presence in
Alice's chat header stayed empty as well.

The profile over REST (`GET /api/users/:id`) returns `presence: null` before
acceptance, checked by the smoke test (`no presence before accept`, `presence
after accept`).

## After acceptance

A tap on «Принять» puts the whole accumulated history on screen, with the «4
непрочитанных сообщения» marker, and the input field is back.

At Alice, coloured double ticks appeared at the same moment: read marks started
flowing.

## Rejection, and a request from a blocked sender

The second request, from Carol, looks the same: the name and «Новая заявка».

«Заблокировать» on the request screen deletes the chat and its messages locally,
closes the screen and removes the row from the list.

A blocked sender nevertheless keeps writing into the chat that already exists:
the server checks blocks only when a direct chat is created (`POST /api/chats`),
and there is no check in `ConversationDO /send`. A minute after the block, a
message from Carol raised the chat back into «Заявки». The contents are still
hidden, but the block itself does not stop delivery.

## Not checked live

The system push for a request on the lock screen. The server sends it without
plaintext (smoke tests `push alert w/o plaintext`, `push badge=0 before
accept`), but the NSE substitutes a preview from the shared database and knows
nothing about requests; `ios/NotificationService/NotificationService.swift` was
not touched in this task. The banner could not be caught on the simulator: once
the app went to the background SpringBoard stopped showing notifications at all,
including ones sent by hand with `simctl push`.
