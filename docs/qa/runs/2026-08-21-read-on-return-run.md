# Read on returning from the background, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`, standing in the direct chat with `charlie` at the bottom of the feed;
`charlie` writes headlessly through `msngrfixture send`.

- The app was sent to the background with the home button; charlie then sent
  «Read me when you come back.» — his copy read `status=1` (sent).
- `01-return-with-unread.png` — the foreground return: the feed is at the
  message with the «1 непрочитанное сообщение» banner above it, the reader in
  front of the message.
- After the return charlie's engine synced (`msngrfixture answer`) and his
  copy reads `status=3` — the read receipt went out on the return.

What this run does not separate: whether the read could also have been marked
while the app sat in the background — charlie's `status=1` before the return
only shows he had not synced yet. The negative half (no read from the
background, none from the chat list) is held by the receipts-run of
2026-08-16.
