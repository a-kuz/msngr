# Deferred envelope: the scheduled send leaves on time from the server

Date: 2026-08-31. Simulator `fable-defer` (iPhone 17, created and deleted for
the run), the alfa fixture home, the shared stand.

## Scenario

1. As alfa, open a chat, type a message, long-press send, pick a time about
   90 seconds ahead. The outbox row goes `ready → inflight → deferred` on the
   server's ack; the server parks the envelope under `defer:{from}/{cmid}`.
2. Kill the app before the deadline (`simctl terminate`).
3. Wait past the deadline. The ConversationDO alarm fires, `drainDeferred`
   journals the envelope through the common `/send` path: the message owns a
   seq and fans out — with no device involved.
4. Relaunch the app. The catch-up replay brings the author's own echo; the
   client closes the outbox row from it: seq stamped on the message row,
   `scheduledFor` cleared, the outbox row deleted. The chat list shows the
   message sent with the deadline's timestamp.

Verified in the run: outbox row `9DB99CBF…` gone, message row seq 3300,
serverTs 19:55:05 against a 19:55:05 deadline, the app killed 19:53:33.

## Two defects found and fixed during the run

Both were the same shape: the `sent` ack rides the live socket, and an author
offline at the deadline never sees it — the row stayed parked forever while
the message had in fact left on time.

- `journal()` now puts the clientMsgId (which the journal already stores) into
  the msg frame, so the author's own echo names the outbox row it closes
  (9afd933). The client finalizes from it on the socket path and the history
  pull alike; `testOwnEchoClosesAParkedSend`.
- The WS catch-up replay in UserDO rebuilt msg frames from `/history` and
  dropped the field — the exact transport the offline author comes back
  through. Fixed in 584b087; the smoke asserts the replayed frames carry it.

## Checks

- `swift test` MsngrKit: 501 tests, 0 failures.
- `node test/smoke.mjs` on a throwaway stand: the defer block green
  (ack with deadline, no early journal, arrival at the deadline, echo with
  clientMsgId, reschedule, cancel), catch-up frames carry the clientMsgId.
  One run tripped the known flaky "no push for own echo" (docs/qa/defects.md);
  it passes on reruns and is untouched by this change.
- The live scenario above on the shared stand.
