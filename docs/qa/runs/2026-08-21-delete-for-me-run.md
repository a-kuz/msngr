# Delete for me, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`, in the direct chat with `charlie`. Screenshots carry the session's tap
grid.

- `01-before.png` — the feed with charlie's «And another.» in place.
- The context menu on someone else's message offers only «Удалить у меня» —
  no «у всех» (the dialog listed a single destructive option).
- After the delete the row leaves the feed and the device database
  (`SELECT count(*)` over the app-group `msngr.sqlite` returns 0 for the
  text); the neighbouring messages stay.
- The peer keeps the message: charlie's engine was brought online to sync
  (`msngrfixture answer`, timed out with nothing new to answer) and his copy
  reads `status=3, deletedForAll=0`.
- `02-after-relaunch.png` — the app killed, relaunched and the chat reopened:
  the message stays gone, with no «Сообщение ещё не загружено» placeholder and
  no gap artifact in its place — the repair machinery does not pull the
  deleted seq back.
