# Run: «не отправлено» reached live, and «Отправить заново» after it, 2026-09-01

The accounting was under units (`spendSendAttempt`, SendFailureTests) while the
live path stayed unwatched: a stopped stand spends no attempts by design, so
the state needed errors thrown while the socket stays alive.

## The rig

A local stand on :8803 behind a forwarding proxy on :8899
(`.claude/fail-proxy.mjs`): everything passes through, WS included, except
`POST /api/media`, which answers 500 while a flag file exists. A fresh user
registered on an own simulator against the proxy, a photo sent into
«Избранное».

## What happened

1. The bubble appears at once with the progress ring; the upload hits the 500
   and the outbox spends an attempt (`send failed … attempt=N` in the log),
   retrying on the 15 s safety net and the 30 s drain timer —
   `2026-09-01-send-failed/retrying.png`.
2. Eleven spends cross `maxSendAttempts = 10`: the ring gives way to the
   failure mark on the bubble («02:09 ⚠»), the outbox row goes `failed` —
   `2026-09-01-send-failed/failed.png`. The WS stayed connected the whole
   time: presence and the chat list kept living through the same proxy.
3. The flag file removed (uploads healthy again), long-press on the failed
   message → «Отправить заново»: the same payload uploads, the message leaves
   and acks — «02:15 ✓», `2026-09-01-send-failed/resent.png`.

## Verdict

The «не отправлено» line is live end to end: spending the attempts, the failed
status in the feed, and the resend from the payload the message was written
with. The roadmap line is done.
