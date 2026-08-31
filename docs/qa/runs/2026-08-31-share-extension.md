# Share extension: a photo shared from Photos lands in a chat

Date: 2026-08-31. Simulator `fable-share` (iPhone 17, created and deleted for
the run), the alfa fixture home, the shared stand.

## Scenario

1. Msngr installed with the new ShareExtension target embedded; the app
   itself killed.
2. In the system Photos app: open a stock photo → share sheet → Msngr shows
   up as a share target with its icon.
3. The extension opens «Куда отправить» — the chats of the shared database,
   most recently active first, requests excluded.
4. A tap on a chat writes the message row and a `ready` outbox entry, the
   original JPEG (1.9 MB) stashed into `media-outgoing`, and the sheet
   closes. Verified in the database before the app ran: kind `photo`,
   `localPath` set, `mediaId` empty.
5. Launching the app drains the outbox: the worker uploads the pending
   original and sends — seq 3381, status sent, outbox empty.

## Checks

- `swift test`: ShareComposerTests (the enqueue leaves a feed row and a ready
  outbox entry; the picker titles a direct chat by its peer and skips
  requests) green.
- The live scenario above against the shared stand.
- Not exercised live: sharing a movie, a plain file and a URL travel the same
  provider paths in `ShareViewController.deliver`; the URL/text path sends a
  plain text message.
