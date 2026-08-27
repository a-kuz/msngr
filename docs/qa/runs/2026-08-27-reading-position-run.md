# The reading position survives between openings of a chat

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803, in the direct chat with Charlie
(1600+ messages of burst history).

## How it works

On leaving the chat the screen stores the seq of the message at the visual
top (`kv` row `feedpos:<chatId>`); leaving from the bottom clears it. On
entry with nothing unread the model publishes the stored seq, and the screen
scrolls there through the same `ensureLoaded` + `scrollWhenReady` path a
search hit uses. The unread banner and an explicit jump (search) outrank the
stored position.

## Seen

- Left the chat with «final 191» at the top of the screen; reopened — the
  feed stood in the same stretch with «final 191» on screen (the restore
  centers the anchored message).
- Left again deeper in the history; reopened — the same stretch again.
- With the reader at the bottom, left and reopened — the feed opened at the
  bottom, no jump into history.
- Two new messages arrived before the next opening — the feed landed on
  «2 непрочитанных сообщения», the banner outranking the stored position.

`ReadingPositionTests` holds the kv round-trip: store, clear-on-bottom,
per-chat keys, empty read.
