# Bulk copy from multi-select, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`, in the direct chat with `charlie`. The screenshot carries the tap grid
of the session it was taken in.

- `01-two-selected.png` — multi-select entered through the context menu's
  «Выбрать», two text messages checked, the «Удалить / Переслать / Копировать»
  bar at the bottom.
- «Копировать» tapped; the simulator's pasteboard read back over
  `simctl pbpaste` holds exactly the two selected messages, one line per
  message with the oldest on top:

  ```
  A deliberately long preview line that will certainly wrap onto a second row in the chat list.
  One more for the counter.
  ```

- The selection mode closes itself after the copy and the feed is back to
  normal.
- The joining rule — feed order reversed to oldest-first, a message with no
  text represented by its preview line, a single message going the usual
  single-copy way — is unit-covered in `MessageClipboardTests`.
