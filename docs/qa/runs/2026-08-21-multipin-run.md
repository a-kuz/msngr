# Several pinned messages at once, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa` (the reseeded trio), in the direct chat with `charlie`. The server
side is held by the smoke («two messages pinned», «one pin removed keeps the
other», «re-pin lands newest-last», «absent seq clears all pins», «pin fans
the chat state out»); the client set lifecycle by `MultiPinTests`.

- A file message and a photo pinned one after the other from the context
  menu.
- `01-bar-two-pins.png` — the bar reads «Закреплённое сообщение 2 из 2» with
  the newest pin's preview, a segmented accent rail on the left counting the
  pins, and the list button in place of the cross.
- `02-walked-to-first.png` — a tap on the bar jumps the feed to the shown pin
  and walks the focus to the previous one: «1 из 2» with the file's preview.
  The walk wraps at the oldest.
- `03-pin-list.png` — the list button opens «Закреплённые сообщения»: every
  pin with its preview and time, newest first, each with its own unpin.
- `04-unpinned-from-list.png` — unpinning from the list leaves the other pin
  in place; the bar behind the sheet is already down to the single-pin form
  with the cross, and the cross takes the last pin down.
- Pins ride the chat state to every member (the smoke's fanout check); the
  local set applies before the server answers, through the action queue with
  one action per seq, so two quick pins cannot swallow each other.
