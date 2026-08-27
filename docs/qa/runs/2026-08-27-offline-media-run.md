# An offline photo survives a kill and is uploaded by the worker

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803, in the `Standup` group.

## How

The stand's processes were killed, a photo was sent from the picker with the
header reading «подключение…», then the app itself was killed and relaunched
still offline. The stand came back last.

## Seen

- Offline, the bubble stood in the feed with the 0 % ring and the clock
  status; the app group held the queue: the source file in `media-outgoing/`
  (`A347A47E….jpg`) and the `outbox` row in `ready`.
- The kill and the offline relaunch changed nothing: the chat list showed the
  «Фото» preview with the clock, the outbox row and the source file were still
  there — the queue lives in the database and a permanent folder, not in
  memory.
- Five seconds after the stand returned the message was acked (`status = sent`,
  `seq = 17`), the outbox was empty, the source file was cleaned out of
  `media-outgoing/`, and the encrypted blob sat in the stand's R2 store.
