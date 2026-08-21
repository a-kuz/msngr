# Everything searched from one field, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa` (the reseeded trio, with a hundred seeded messages in the charlie
chat). The ROADMAP still carried this as "the FTS table is filled but nothing
queries it yet" — the implementation had landed since (`MessageSearch` over
`messageFts`, `ChatSearchResults` with its three sections); this run closes
the claim with what the screen shows.

- `01-message-hit.png` — «message 42» typed into the chat list's search
  field: the «Сообщения» section finds «Test message 42 of 100» with the
  match highlighted in the accent colour.
- `02-landed-on-message.png` — tapping the hit opens the chat with the feed
  standing on message 42, mid-history.
- `03-three-sections.png` — «bravo» in the same field: «Чаты» answers
  instantly with the local chat, «Сообщения» brings the FTS hit
  («Hi, Bravo.»), and «Люди» lists the server's matches by username —
  including accounts this device has never talked to.
- A query with no matches shows «Ничего не нашлось» with the hint of what is
  searched.
