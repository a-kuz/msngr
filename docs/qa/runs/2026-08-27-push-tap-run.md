# A system push arrives and its tap opens the chat

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5) with the
`alfa` home against a private stand on :8803, whose `APNS_HOST` points at the
dev mock (`node server/tools/apns-mock.mjs --port 9873 --log`). The sender is
headless: `msngrfixture send --as charlie --to alfa`.

## Seen

- The app was sent home; two seconds later charlie sent «push tap probe».
- The mock accepted the stand's POST and delivered it through `simctl push`
  within half a second (`push token=165449DB… badge=1 stamp=49 delay=484ms`).
- The system banner appeared over the home screen with the sender's name and
  the text — the app, still alive in the background, had already processed the
  envelope — and the icon badge read 1.
- The tap opening the chat: the banner dismissed itself before the scripted
  tap landed, and the behaviour was confirmed by the owner watching the run
  (2026-08-27): tapping the push opens the chat.
