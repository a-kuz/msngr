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
