# Send again rebuilds a missing queue entry — live run

2026-08-30, iPad Pro 11" simulator (fable-ipad), a private stand on :8811 with
fresh state. The change under test: `SyncEngine.retrySend` no longer refuses a
failed message whose outbox row is gone — it rebuilds the queue entry from the
message row itself.

## The state under test

The dead end this closes: a message marked failed after its outbox row was
already deleted. The old code answered «Отправить заново» with an alert that
the message can no longer be sent, while its full text sat in the message row.

Reaching that state live needs a send caught mid-flight by a dying socket
(~50 stand restarts never produced it — a stopped stand waits at `guard
connected` and retries forever by design), so the row state was planted
directly:

1. Registered a fresh user against the stand, opened «Избранное».
2. Killed the stand, sent "Retry me retry me" — the bubble held the clock,
   the row sat at `status=0, seq=NULL`, the outbox row at `ready`.
3. Terminated the app; in `msngr.sqlite`:
   `UPDATE message SET status=-1, failReason='sendFailed'; DELETE FROM outbox`.

## The run

4. Stand back up, app relaunched: the bubble shows the failed mark.
5. Long-press → «Отправить заново».
6. Within a second the bubble carries a tick and the fresh time; the row reads
   `status=1 (sent), seq=1, failReason=NULL`. No alert appeared at any point.

## Verified alongside

- `swift test` in MsngrKit: All tests passed (457 tests), including the two
  tests that pin this path — `testRetrySendRebuildsAMissingQueueEntry` and
  `testRetrySendIgnoresADeliveredMessage`.
