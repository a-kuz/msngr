# Contact and location messages

Date: 2026-08-31. Simulator `fable-cl` (iPhone 17, created and deleted for the
run), the alfa fixture home, the shared stand.

## Scenario

1. A vCard (`Ada Lovelace`, phone + email) added to the simulator's address
   book with `simctl addmedia`.
2. In a direct chat, the attachment menu shows «Геопозиция» and «Контакт».
3. «Геопозиция» opens the map picker (a center pin over an Apple map, the
   send button in the toolbar); sending produced a bubble with a cached
   `MKMapSnapshotter` picture and the pin — seq 3, status sent.
4. «Контакт» opens the system contact picker; picking Ada produced the card
   bubble (initials, name, phone) — seq 4, status sent. The payload carries
   `{"name":"Ada Lovelace","phones":["+1 555 0100"],"emails":["ada@example.org"]}`
   and nothing else — a card, not an address-book reference.
5. A tap on the location bubble opens the full map with the marker and
   «Открыть в Картах»; a tap on the contact bubble opens the card sheet with
   copyable rows and «В Контакты».

## Checks

- `swift test` MsngrKit: ContactLocationTests (payload roundtrip, the message
  columns, the previews) green; the full suite green.
- The live scenario above; both rows reached the journal (seq 3 and 4) and
  the chat list previews name the content.
- Not verified live: the receiving side's rendering (the host was at its
  four-simulator limit); the apply path is the same `applyContent` the tests
  cover, and the bubbles render from the stored row on both sides.
