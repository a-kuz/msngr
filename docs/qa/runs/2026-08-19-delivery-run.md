# Delivery: the fanout queue measured, then made outbox-to-inbox

Date: 2026-08-19, branch `run-delivery`. Agent stand: own `wrangler dev` on
:8833 (`APNS_HOST` → :9893, `PERF_LOG=1`), APNs mock on :9893, simulators
`run-delivery-a` (delivera) and `run-delivery-b` (deliverb), both deleted after
the run. Three recorded defects pass through this queue: the burst landing at
one message per second, the delivery ticks stopping after the head of a burst,
and the pin frame that stood 235 s; during the run the owner added a fourth
with an acceptance bar — chats must work with APNs fully down.

## What the measurements said (before)

`server/test/tick-burst.mjs` (taken from run-ticks) against the unchanged
queue, burst of 100, one recipient with a push token, APNs answering in 150 ms:

```
ack of the last send:      103 ms
landed on the recipient:   100/100 in 15 669 ms
gap between arrivals:      p50 157  p90 161  max 169 ms
second ticks (lag):        p50 8 092  p90 14 329  max 15 736 ms
```

At `PUSH_LATENCY_MS=1000` the arrival gap became p50 1 008 ms — the gap tracks
the APNs round-trip one for one. That is the whole "burst at one per second"
defect: `UserSessionDO./event` awaited the APNs call, and the chat's queue
delivered head-of-line, so the delivery rate of every chat equalled the push
latency of its slowest recipient. The first delivery pass itself started
within ~10 ms of the send; nothing else in the path cost anything comparable.

The tick lag had the same cause seen from the other side: the delivered
receipts to the author queued behind the recipient's still-undelivered
messages, so a tick arrived only when the queue drained past it — p50 8 s on
a 15 s burst, minutes on a real device, which reads as "ticks stop after the
head".

A recipient that failed was worse than slow: after three passes (200 ms, 1 s)
the frame was dropped for good. `probe-drop.mjs`: with the recipient's session
rejecting 10 deliveries, the frame died in 2.5 s and never reached the live
socket. A recipient timing out (10 s per delivery) also held every other
recipient of the chat for up to three timeouts. That is the class the 235 s
pin frame and the shared-stand APNs incident belong to.

## What changed

Three commits on the server, no client change:

1. **The fanout queue is an outbox** (`ConversationDO`). One delivery record
   per recipient per frame (`fr:<userId>/<jobId>`), alive until the
   recipient's session object acknowledges it: a failure moves the record's
   deadline out on a growing pause (200 ms → 10 s, the last repeating) and
   never gives it up. Each recipient has an independent delivery chain —
   order is guaranteed per recipient, and one recipient failing or timing out
   delays nobody else. Chains are pumped by the requests that enqueue;
   the alarm is a watchdog that re-runs whatever a dead isolate left behind.
   Two workerd lessons are encoded here: `setAlarm` during a running alarm
   handler cancels the handler mid-await (it wedged the stand for 654 s in
   one probe run), so arming requests collect while the handler runs and are
   armed as it leaves; and a shared `Promise.all` barrier across recipients
   quietly re-couples them — the first rewrite kept an 8 s tick lag until the
   chains got their own loops.

2. **The push left `/event`** (`UserSessionDO`). Frame delivery is
   acknowledged once the sockets have the frame; the APNs call goes through a
   persisted per-user queue drained by the alarm (shared with the presence
   TTL through a stored deadline). A push job whose APNs call failed in
   transit is retried on a growing pause (1 s → 30 s) until every device has
   it, with the devices already served written down — a retry reaches only
   the ones still owed, and a refusal APNs actually pronounced stays final.
   The receiving side got the idempotency mark the outbox retries rely on:
   msg frames arrive per chat in seq order, so one mark per chat
   (`in:<chatId>`) answers a redelivery at or below it with "already have
   it" — a retry never applies twice and never costs a second push.

3. **The retry ceiling is 10 s** — what a recovered recipient waits for its
   backlog at worst, and what a dead one costs per chat: one delivery call
   per pause.

## The same measurements after

Burst of 100, APNs answering in 150 ms:

```
landed on the recipient:   100/100 in 255 ms      (was 15 669 ms)
gap between arrivals:      p50 0  p90 2  max 181 ms (was p50 157)
second ticks (lag):        p50 31  p90 204  max 247 ms (was p50 8 092)
```

At 1 s APNs latency the numbers hold (landed in 34 ms, tick lag p50 5 ms):
the push pace is no longer the chat's pace. `BurstTicksTests` (two live
clients, real E2EE, file databases): 100 landed in 306 ms, gap max 54 ms,
every tick within 106 ms of its message. `probe-drop.mjs`: a recipient
failing twice gets the frame 1.2 s later instead of losing it.
`fanout-load.mjs` (500-frame rounds, fault rounds with rejected deliveries):
all rounds green, queue drains to empty.

`probe-apns-down.mjs` is the owner's acceptance bar end to end: with nothing
listening on the APNs port, a burst of 10 lands on the live socket in 23 ms
and every message earns its delivered receipt; when the endpoint comes back,
all 10 pushes catch up in 2.3 s with zero duplicates.

## The live run (two simulators)

- **Burst of 100.** The stand was killed, 100 messages were typed on the
  sender — all queued with the clock status, «подключение…» in the header.
  The stand came back: the first send left 128 ms after the port answered,
  all 100 were on the recipient's screen and double-ticked on the sender
  16.4 s after stand-up. That pace is the client's outbox (send → ack →
  next, a ratchet step each), not the server queue; on the wire the fanout
  added milliseconds per message.
- **APNs fully down.** With no APNs mock running, 10 more messages landed on
  the recipient instantly and every one double-ticked on the sender — the
  exact scenario that froze the shared stand. The server logged failing push
  attempts and kept the jobs.
- **APNs back.** The mock came up: 111 queued pushes caught up in ~13 s
  (`apns-mock.log`, accepted 112 / delivered 111 — the one failure is a
  smoke-test token naming no real simulator), and the recipient's screen
  showed no repeated banner: the messages were already on it, and the
  foreground app suppresses a push about a message it has shown.

## What this closes and what it does not

- The burst-at-one-per-second and ticks-stop-after-the-head defects are
  closed by the same change, measured before and after.
- The dead-APNs acceptance bar holds: frames and ticks never touch APNs, and
  pushes owed survive the outage.
- The 235 s pin frame was never reproduced as such; what is closed is the
  class it belongs to (a frame given up on after three attempts, a queue
  standing while recipients fail). The stall log
  (`fanout: ... waited ...ms before delivery`) survives to say so if it
  returns.
- `blink` from the per-user-DO design (the server marking delivered on a
  device coming online) is **not needed as a separate change today**: the
  client already writes the delivery receipt into its database before
  sending it (`DeliveryReceipts.record` + `pendingAction`), so a receipt
  survives a dying socket and is retried on reconnect, for live frames and
  catch-up alike. It becomes necessary when the journal moves into the
  user's object — noted for that step, not this branch.

## Verified with

`make check DEV_UDID=14C70E21…` green (xcodegen, build, `swift test`,
MsngrTests, server smoke, no fresh crashes); `BurstTicksTests` against the
own stand; `tick-burst.mjs`, `fanout-load.mjs` (clean and fault),
`probe-drop.mjs`, `probe-apns-down.mjs`; the two-simulator live run above.
