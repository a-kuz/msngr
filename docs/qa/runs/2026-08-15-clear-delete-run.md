# Clearing history and deleting a chat

Clearing is a local act: the ratchet moves forward and destroys the keys of
every message it opens, so the copy on the device is the only one it will ever
hold, and the peer keeps his. Deleting a direct chat takes it off this user's
list only — the conversation object keeps the journal and the membership, and
the chat comes back on the next message the peer writes. A group is left.

Screenshots — `2026-08-15-clear-delete/`. Run date: 2026-08-15.

## Stand

Own simulators `msngr-task52-a` (DAE4D6DB) and `msngr-task52-b` (712BB08E),
iPhone 17, iOS 26.5, deleted after the run. Own `wrangler dev` on :8817 with
`--persist-to server/.wrangler-task52` (D1 migrations applied into the same
directory) and `APNS_HOST` pointed at an unused port. Both apps launched with
`MSNGR_SERVER=http://localhost:8817`, build from the working tree. Users
`5201` (Алина, device A) and `5202` (Борис, device B). The client database was
read straight from the app group container of device A.

## Run

| Step | Expectation | Fact |
|------|-------------|------|
| A writes three messages, B accepts and answers | four messages on both devices | as expected (`01-a-before.png`, `02-b-before.png`) |
| A opens the chat settings | clearing and deleting sit apart from the rest | `03-a-chat-settings.png` |
| A taps «Очистить историю» | the confirmation says what goes and what stays | «Сообщения этого чата удалятся с этого устройства. У собеседника они останутся.» (`04-a-clear-confirm.png`) |
| A confirms | the open chat empties, no stale feed, no crash | `05-a-cleared.png` |
| B looks at the same chat | all four messages still there | `06-b-keeps-history.png` |
| B writes into the cleared chat | the message lands and is readable | `07-a-new-message-after-clear.png`; on A `lastSeq=5 syncedSeq=5 myReadUpTo=5 unreadCount=0`, one message row, `historyGap` and `pendingDecrypt` empty |
| A taps «Удалить чат» | the confirmation says the peer keeps his copy and the chat can come back | `08-a-delete-confirm.png` |
| A confirms | the screen returns to the list and the chat is gone | `09-a-list-after-delete.png`; on A no chat, no messages, no members, tombstone at seq 5, action queue empty |
| B looks at his list | the chat is untouched | `10-b-list-unchanged.png` |
| B writes again | the chat comes back with that message alone and one unread | `11-a-chat-returned.png`, `12-a-returned-chat.png`; `lastSeq=6 syncedSeq=6 syncCursor=6 myReadUpTo=6`, one message row, no gaps |
| B seeds 100 messages, A clears mid-flight | the feed restarts under the arriving stream | cleared at seq 14, the feed continues from `Test message 9` (`13-a-cleared-mid-burst.png`) |
| the burst finishes | nothing lost, nothing doubled, nothing unreadable | 92 rows with seq 15…106, 92 distinct, `syncedSeq = lastSeq = 106`, `historyGap`, `pendingDecrypt` and `outbox` all empty (`14-a-after-burst.png`) |

The returning chat is the point of the tombstone: without it the new chat row
would start at cursor 0 and the catch-up would ask the server to replay the
whole journal — envelopes this device decrypted once and can never decrypt
again. It resumed at 5 instead, and the only thing it fetched was seq 6.

## Server side

`node test/smoke.mjs` against the same stand, all pass, including the section
added for this work:

```
ok   direct chat deleted
ok   deleted chat leaves the deleter's list
ok   peer keeps the chat and its journal
ok   deleter's read mark is at the end of the journal
ok   message into a deleted chat still reaches the deleter
ok   chat comes back on the next message
ok   group delete leaves the group
ok   the others see the member gone
ok   deleting a chat you are not in is refused
```

## What the run did not cover

Deleting a group from the interface: the request is the same one the smoke
covers end to end (`group delete leaves the group`), but no group was built on
the two devices by hand. Clearing a chat that holds attachments — the files are
removed with the rows, and only text messages were used here. Deleting while
offline, where the request waits in the action queue and the snapshot keeps the
chat out until it lands.
