# Two yellow lines that turned out unreachable live, not just unverified

Date: 2026-08-28. A private stand (`wrangler dev --port 8803`, its own
persist dir under `server/.wrangler`, `APNS_HOST` pointed at an unused local
port) and a fresh trio seeded with `msngrfixture seed --base
http://localhost:8803` (`alfa4`/`bravo4`/`charlie4`, kept in
`.claude/fixtures/msngr-7b-local`, not the shared trio). No app UI was built
for this: `msngrfixture` runs the same `MsngrCore` engine (`SyncEngine`,
outbox, `E2EEManager`) the app does, headless, so the outbox/status columns
were read straight from `msngr.sqlite` on the account's own device directory.

## ROADMAP ~397: «не отправлено» once the attempts are spent

Read first (`SyncEngine.swift:1975-2051`): `drainOutbox()` starts with `guard
connected, !draining else { return }`. A network error inside
`sendOutboxItem` bumps `outbox.attempts` and, past 10, calls
`markSendFailed(reason: .tooManyAttempts)` — but that `catch` only runs for an
error a live `sendOutboxItem` actually threw. While the client is
disconnected, the whole function returns at the guard before an item is even
tried, so no attempt is spent. The only place `SendFailure.tooManyAttempts`
has any test at all is `SendFailureTests.testExplanationPerCode`, which
checks the string, not the path that reaches it — grepping
`ios/MsngrKit/Tests` for a test that drives `attempts` past 10 through
`drainOutbox` (as opposed to the unrelated `pendingDecrypt`/message-repair
`attempts` columns) found none.

Live: four fault-injection runs against the local stand, in increasing
precision —
1. a single send racing 4 kill/restart cycles of the stand,
2. the same with 8 messages and a tighter kill loop,
3. sampling `outbox.attempts` every 0.5 s across 8 cycles,
4. starting the send with the stand already down, then 20 rapid up/kill
   cycles (~1 s up each) before leaving it up for good —

about 50 kill/restart cycles of the local `wrangler dev` process (`kill -9`)
in total, spanning direct and group chats. In every run the message ended up
`status = 1` or `2` (sent/delivered) once the stand came back, and
`outbox.attempts` was never observed above its initial value: a `select
group_concat(attempts) from outbox` sampled through the chaos came back
either empty (item already gone, delivered) or unchanged. The path that
spends an attempt needs `sendOutboxItem`'s own `ws.send()` to throw while the
engine still believes it is connected — a send caught exactly at the moment a
live socket dies, not "the stand was down for a while". Stopping and
restarting a stand — this repo's definition of offline — never produced that
window in ~50 tries.

One side finding from these runs, not a defect: `msngrfixture`'s own
account-verification call on startup is a plain HTTP request with no outbox
behind it. Hitting a dead stand at that exact moment throws a raw
`NSURLErrorDomain -1004` and the tool logs "registering again" — it recovered
to the same account both times this happened (same `userId`/`deviceId` in
`meta.json`), so no state was lost, but it means a `msngrfixture send`
launched with the stand already down is not itself a resilience test — only
the outbox drain after a successful start is.

**Verdict:** the line's premise doesn't hold. "не отправлено after attempts
are spent" is real code with zero coverage, live or unit, and it is not
reachable through what this repo calls offline (a stopped stand) — by design,
per `guard connected`, a stopped stand never spends an attempt, it just waits
and retries forever, which is the "nothing ever fails" behavior the product
wants. The only place `MessageStatus.failed` is reached live is the sibling
line right above it (395, ✅): the server explicitly answering `{t:"error"}`
to a live `send` (`SendFailureTests`, `applyServerError`). Suggested wording
for 397, pending agreement, since changing product behavior is out of scope
here: "the exhausted-attempts branch of the outbox (`attempts > 10`,
`SyncEngine.swift:2041`) has no live or unit coverage and could not be
triggered by ~50 stand restarts — it needs a send caught mid-flight by a
dying socket, not a stopped stand; only the explicit-server-rejection path
above it is exercised."

## ROADMAP ~470: a delete arrived before the original

Read first: `ConversationDO.pumpUser` (`server/src/do/ConversationDO.ts:378-448`)
delivers one recipient's queued frames "in the order the chat produced them" —
a single chain per recipient (`pumping` set), FIFO by an incrementing id, and
`fanoutRetryable` only excludes `typing`; a `deleted` frame is retried like
everything else, never dropped, so it can't leapfrog a content frame stuck on
backoff. `UserDO`'s push trigger is gated on `frame.t === "msg"`
(`UserDO.ts:319`) — `deleted` never raises a push, so there's no push-timing
race either. Client-side, `drainIncoming` applies frames "in the order frames
arrived in" (`SyncEngine.swift:368-386`), single actor, nothing concurrent.
Together: for one device, over the live socket or over catch-up, a `deleted`
frame cannot reach the client before the `msg` frame of the seq it targets.

Live: seeded a fresh direct chat, had `alfa4` send a text to `bravo4` while
`bravo4`'s engine was not running, then `alfa4` deleted it for everyone
(`bravo4` still not running), then started `bravo4`'s engine to catch up.
Per `docs/protocol.md:281` ("tombstones are skipped as `msg` frames in a page
and arrive as `deleted`"), the already-tombstoned seq never came down as a
`msg` frame at all — only the `deleted` frame did, and confirmed by reading
`bravo4`'s `pendingApply` table: a row was buffered for it, keyed
`(chatId, targetSeq)`, matching `bufferPendingApply`'s behavior when `apply`'s
direct `UPDATE ... WHERE seq = ?` finds no row. But that row cannot ever be
flushed — the content is gone from every future catch-up page, not "applied
later" — so this live case is adjacent to the ROADMAP line, not a match for
it.

The scenario the line and `ServiceFrameTests` actually describe —
`pendingApply` written, then flushed once the original does arrive — needs
the `deleted` frame to be applied while the content frame that came before it
on the wire is still sitting undecrypted in `pendingDecrypt` (the documented
"a message that arrives before its key" case, group chats, a missing sender
key). Forcing that gap live needs the sender-key handout to lag its own
content frame by enough for a same-connection delete to land in between, and
I could not engineer that deterministically in the time available (a
process-freeze approach to pause `bravo4` mid-delivery was not conclusive)
— I'm not claiming it's impossible, only that I didn't reproduce it live.

**Verdict:** no ordering violation found anywhere reachable — server fanout,
push gating and client apply order all independently prevent it for a single
device under normal conditions. The line stays yellow: I have unit coverage
(`ServiceFrameTests.testDeletedBeforeOriginalAndReplay`) and a structural
argument for when it's reachable (a decrypt lag, not a network reorder), but
not a live reproduction of the exact "buffered, then flushed" sequence.
Suggested wording for 470, pending agreement: "covered by
`ServiceFrameTests`; the live trigger is a content frame stuck in
`pendingDecrypt` behind a missing group sender key, not a network reorder —
server fanout and client apply are both strictly ordered, confirmed by
reading `ConversationDO.pumpUser`, `UserDO`'s push gate and
`SyncEngine.drainIncoming`."

## Not done

Neither line was flipped to ✅ — the point of this run is that both had less
behind them than "not verified live" suggested, not more. No defect filed:
the underlying behavior is either working as designed (397 — sends really do
survive a stopped stand and never fail) or unreproduced either way (470). No
app UI build was needed since the same production engine code was exercised
headless.
