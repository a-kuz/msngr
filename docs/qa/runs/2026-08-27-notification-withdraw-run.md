# Delivered notifications leave the shade when the chat is read

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5) with the
`alfa` home against a private stand on :8803 and the dev APNs mock on :9873.
The sender is `msngrfixture send --as charlie --to alfa`.

## Seen

- With the app sent home and then suspended, two pushes stacked in the shade
  as raw «Новое сообщение» (the extension does not start on the `simctl push`
  path) plus one older notification for the bravo chat; the icon badge read 2.
- The app was launched; it came back on the charlie chat, both messages on
  screen, the chat read.
- The shade after that: the pushed stack was gone — the charlie notifications
  and the bravo one, whose message had been read earlier — and the icon badge
  was gone with it. The sweep is `dropReadNotifications`: on every unread-count
  emission it collects the delivered notifications' `(chatId, seq)` and removes
  those at or below the chat's `myReadUpTo`.

## Found in passing

Returning to the open chat also *posted* a banner for «withdraw probe» — a
message already on screen — and that one notification was still in the shade a
minute after its message was read. Logged in docs/qa/defects.md; the
withdrawal of the pushed stack above is not affected by it.
