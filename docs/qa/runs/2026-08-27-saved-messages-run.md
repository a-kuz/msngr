# Saved messages: the chat with yourself

Run on 2026-08-27 on a fresh `iPhone 17` simulator (`solo-saved`, iOS 26.5)
holding the `alfa` home from the fixtures, against the shared stand on :8787.
The build is the working tree of this commit.

## What the server does

`POST /api/chats {kind:"self", memberIds:[]}` creates the chat `self:<userId>`
with the caller as its only member; a second call returns the same id. The
message to yourself gets a seq like any other, and no push leaves for it: the
author's own echo never enters the push queue (`UserDO`, `isOwnEcho`), which
was already the rule for every chat. Smoke on a throwaway stand: 275 checks,
ALL PASS, including the five new ones (`self chat created`, `self chat is one
per user`, `send to yourself gets a seq`, `saved messages raise no push`,
`self chat lists its one member`).

## What the client does

The chat is created by the client on the first snapshot that has no chat of
kind `self`: alfa's home, seeded before the feature, got its «Избранное» on
launch (`GET /api/chats` → `POST /api/chats` → `GET /api/chats` in the stand
log, one round). A kill and a relaunch showed one such chat, not two.

Seen on the device:

- the chat list: «Избранное» is the first row, above the pins, with a bookmark
  on a blue circle in place of the initials; its row shows the last message's
  preview and the single tick of a sent message;
- the chat: the title and the bookmark in the header, an empty-state hint
  «Заметки для себя»; a typed text goes out and lands with one tick (there is
  no peer to deliver to, so the status stays at "sent" by design);
- forwarding: a long press on a message in the group `Random` → «Переслать»
  → the picker lists «Избранное» first → the message appears in the saved chat
  with «Переслано от Bravo Service» above it, and the list row updates to it;
- the info screen: bookmark, «Избранное», attachments, mute, auto-delete and
  «Очистить историю»; no «Удалить чат» and no username line;
- the row's trailing swipe offers mute and archive only; no delete.

Core suite `swift test`: 383 tests, 0 failures. MsngrTests: see the gate log
of the commit.

## Also in this run

The owner asked, while watching the run, to drop the «История начинается
здесь» line at the top of a feed; the `historyStart` feed item is gone with
its string and its three unit tests. The empty-chat hint was first written as
a sentence that wrapped to a lone word on the second line; it is now three
words.

The `idb ui text` trap from `docs/qa` still holds: a fresh simulator types in
the guest's Russian layout, so the note came out as «Ашкые тщеу ещ ьныуда».
It proves the send path and nothing about the text.

## Not covered

A second device of the same account reading the saved messages: the fixtures
have one device per account. The pairwise path this uses is the one a direct
chat already uses for its own devices, and nothing here changed it.
