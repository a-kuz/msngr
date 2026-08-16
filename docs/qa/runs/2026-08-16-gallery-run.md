# Attachment gallery — live run, 16 August 2026

Stand: own `wrangler dev` on :8809 (`--persist-to .wrangler-gallery`, APNs host
:9879), own simulator `msngr-gallery` (A3516574-59C6-4FBE-8A45-AE22281AB05A,
iPhone 17, iOS 26.5), build from this branch.

Chat: `gallery_a` (registered in the app) to `gallery_b`, a peer registered
straight against the API with real X25519/Ed25519 keys. Only the sending side of
the chat is exercised: the peer has no device listening.

Content: 100 text messages, then ten rounds of the debug seed (`Отправить
вложения ×10` in chat settings) — a photo, an album of three, a video, a file, a
voice message and two link messages per round. 171 messages, all `status = sent`,
media uploaded (`mediaId` present in every row).

## What was checked

| Step | Evidence |
| --- | --- |
| Grid paging to the oldest item (40 entries, one page each of photo/video/album) | reached round 1 by scrolling, no gaps or repeats |

## Found and fixed during the run

List rows built as `Button { } label: { row }` did not fire on the files and
voice tabs — the tap reached neither the preview nor the log put in to catch it,
while the same row on the links tab worked. Rows now carry
`contentShape` + `onTapGesture`, the way the grid cells do, and all three tabs
open their entries.

## Not covered

Incoming attachments: the peer is an account without a device, so everything in
this chat was sent from the phone under test. Nothing in the gallery reads the
direction of a message, but a run with two live devices would cover the
not-yet-downloaded thumbnail (BlurHash placeholder) properly — here every
attachment was already in the cache of the device that sent it.
