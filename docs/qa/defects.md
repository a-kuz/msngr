# Defect log

Defects reported by the owner, one entry each. An entry stays until the fix is
merged and the owner's scenario was re-run; then it moves to the closed list
with the commit that closed it.

## Open

### Sends to pre-binding accounts hang, and block everything behind them
Reported 2026-08-19 from the device, after a rebuild: «не отправляются
сообщения». The stand and the tunnel were healthy (probe-send.mjs green through
both), and a fresh-to-fresh send through the real core passed in half a second —
the device's own sends were the ones stuck. The device was writing to the
owner's older accounts (`aakuz`, `akuz2`), registered before the identity
binding: 2354 of 2514 rows in `identity_keys` on the stand carry no
`identity_key_sig`. A bundle whose signature does not verify made
`X3DH.initiate` throw out of the whole send, the outbox counted attempts toward
a hard failure, and — worse — the first such message head-of-lined the outbox:
nothing behind it sent to anyone, which read as "messages do not send" at all.
The visible loop of `GET /prekeys` every ~30 s was the outbox retrying.

Fixed: a device whose bundle does not verify is skipped (a recipient with no
usable device is `noUsableKeys`), and `drainOutbox` sets such an item aside for
the pass instead of failing it or letting it block the queue — the message
keeps its clock and sends the moment the recipient's account heals (it
publishes its identity on the first start of a current build).
`testUnsignedRecipientDoesNotBlockTheOutbox` reproduces both halves. The old
accounts on the owner's other devices and simulators still need one launch of a
current build each to become reachable.

### Messages do not send
Reported 2026-08-19, urgent. Two causes were found behind it, both confirmed.

The shared stand's worker took a `Segmentation fault: 11` and answered 503 for
about four minutes (`POST /api/register`, `POST /api/push-token` in
`.claude/wrangler-8787.log`) before workerd came back on its own. Nothing on our
side asked it to; what the crash was is not established.

Under that, a permanent one: the identity binding merged in `eed62e8` added
`identity_key_sig` with `DEFAULT ''`, and on the stand 2357 of 2360 rows in
`identity_keys` carry that empty default. A client refuses a bundle without the
signature (`newSessionBox` returns nil), so every device of the recipient stayed
without a box and the envelope went out addressed to nobody — the sender saw a
sent message that reached no one. Fixed on both ends: the send now fails with
`noUsableKeys` when no device of a recipient could be encrypted to, so the outbox
keeps the message; and `POST /api/identity` lets a device publish its own binding,
which `SyncEngine` does once per start, so an account older than the signature
heals itself.

### A deleted direct chat cannot be brought back
Reported 2026-08-19. Deleting a direct chat drops `chat:<id>` from the deleter's
`UserSessionDO` while `ConversationDO` keeps the membership. Opening the
conversation again went to `POST /api/chats`, `ConversationDO./create` saw the
existing meta, answered `existed: true` and did nothing else: the id came back,
the chat did not, and the client's tombstone guard would have dropped the chat
state anyway. Only a message from the peer restored it. Fixed by re-listing the
chat for the caller and re-sending its state on `/create`, and by lifting the
tombstone on the device's own act of opening the chat. Smoke covers the reopen.

### A burst arrives at one message per second
Reported 2026-08-19 from the device: 100 messages leave the sender at once and
land on the recipient one per second. Nothing in the code paces sends — no rate
limit on the server, no sleep in the outbox — so the second is spent somewhere
per incoming message: the ratchet step under `CryptoGate`, the per-message
transaction, or the fanout queue waking once per delivery. Measure first
(`MSNGR_PERF=1` writes a span per stage), then fix. Statuses are the owner's
bar here too: the tail of a burst must not trail behind by a minute and a half.

Measured and fixed on run-delivery (`runs/2026-08-19-delivery-run.md`): the
second per message was the APNs call awaited inside `UserSessionDO./event`,
serialized by the chat's head-of-line queue — the arrival gap tracked the push
latency one for one (157 ms at a 150 ms mock, 1 008 ms at 1 s). With the push
moved to its own queue a burst of 100 lands in 255 ms, gap p50 0 ms.

### Delivery ticks stop after the first messages of a burst
Reported 2026-08-19 from the device (iPhone 15 Pro Max against the shared
stand). The recipient has all 100 messages of a burst on screen, while the
sender shows the double tick on the first two only — the other 98 keep the
single «sent» tick. So the delivered receipt covers the head of a burst and
never arrives for the tail, or the tail's marks never reach the sender.
Screenshots in the report; both sides were online the whole time.

The bar the owner set for this: statuses are the hardest and most important
thing in the product and have to be flawless — WhatsApp-grade, where every
tick updates the instant the state changes. That is the acceptance test, not
«the receipt eventually arrives».

Same root as the burst pace, fixed on run-delivery: the delivered receipts to
the author queued behind the recipient's still-undelivered messages (tick lag
p50 8.1 s on a 100-burst). With one independent delivery chain per recipient a
tick follows its message by p50 31 ms on the wire and within 106 ms between two
live clients (`BurstTicksTests`); the live run shows the whole burst
double-ticked (`runs/2026-08-19-delivery-run.md`).

### A dead APNs endpoint stops chats
Reported 2026-08-19 from the shared stand: with nothing listening on the APNs
port, new messages stopped arriving entirely — the owner hit it right after
deleting a 20k-message chat, but the deletion was incidental. The chain:
`UserSessionDO./event` awaits `pushToDevices`, the push retries three times
against a dead endpoint, and the fanout queue of the chat is head-of-line, so one
undeliverable push holds every following frame; the stand had piled up ~20k
retried pushes of a single message by the time the mock came back, and the worker
itself wedged along the way. The owner's bar, recorded as acceptance: chats must
work with APNs fully down — the socket delivery and the push must not share a
fate. run-delivery is the fix in flight; its live run has to include this exact
scenario.

How the worker died, from `~/.wrangler/logs/wrangler-2026-08-19_16-15-26_335.log`
(7.8M lines): the delivery timeout aborts `/event` after 10 s, but the push
fetches that call had already started keep running; the retry invokes `/event`
again and starts three more. 20 067 `waited before delivery` errors and 19 816
accepted pushes of one message later, workerd hit `Too many open files`
(`kj/async-io-unix.c++:918`) and stopped opening sockets at all.

Done on run-delivery and run live (`runs/2026-08-19-delivery-run.md`): /event
acknowledges at the socket and the push goes through a persisted queue that
retries owed pushes on a growing pause. With nothing on the APNs port, 10
messages landed between two simulators instantly with every tick; when the mock
came back, 111 queued pushes caught up in ~13 s with no repeated banner.
`probe-apns-down.mjs` keeps the scenario runnable. The FD-exhaustion chain dies
with the cause: nothing awaits a push inside a delivery any more, so an aborted
delivery no longer leaves fetches running.

### The caret jumps in front of the first typed character
Reported 2026-08-19 from the device, screen recording
(`ScreenRecording_08-19-2026 20-16-45_1.MP4` in the owner's Downloads). Typing
"123" produces "231": the first character lands, then the caret moves in front
of it, so everything after types before the first. Points at the composer's
text binding rewriting the field's text and resetting the selection while the
first keystroke is still being composed.

Cause and fix, 2026-08-20: the composer's programmatic write restored the caret
by its absolute position. When the binding runs ahead of the view — the first
character of a field the view still reports as empty — that position is 0, so
the caret landed in front of the character just typed and «123» came out
«231». The write now keeps the caret's distance from the end of the text
instead. `ComposerCaretTests` fails on the old rule (caret 0, order «231», a
restored draft's caret at its start) and passes on the new one; MsngrTests green
whole. Not re-run on the owner's device yet.

### The dark theme is missing something
Reported 2026-08-19 from the device, with a screenshot: «темная тема чего-то не
хватает». Checked live on a simulator in the dark appearance, 2026-08-20
(`runs/2026-08-20-dark-theme/`): the large title «Чаты» is white and legible, so
the reading that it vanishes was wrong. What the dark appearance does lose is
the empty-screen glyph — the accent at 55 % over a near-black ground turned to
mud (`list-before.png`) — fixed through a `Theme.decorativeGlyph` role that
carries a different opacity per appearance (`list-after.png`).

Open beyond that, and a taste call for the owner: the chat list itself is pure
system black in the dark appearance, while in the light one the palette tints
every screen (cream for graphite). The dark theme therefore carries none of the
palette's identity. The other screens still need the same look-over.

### The in-app banner does not react to a tap
Reported 2026-08-19 from the device. Tapping the in-app notification banner does
nothing; it has to open the chat it announces. The tap-opens-chat path exists and
was checked on the simulator (push-client/inapp-banner-tap-open-chat), so either
the hit area or a gesture conflict kills it on the device — same family as the
row hit areas below.

### List rows are tappable only on their letters and icons
Reported 2026-08-19 from the device. In many lists the tap works only exactly on
the text or the icon, not anywhere in the row — the hit area does not cover the
whole cell. Sweep the lists (settings, folders, chat info, search results) and
give every row a full-width content shape.

### The context menu opens under the keyboard
Reported 2026-08-19 from the device, with a screenshot. Long-pressing a bubble
while the keyboard is up shows the reaction bar and the lifted bubble correctly,
but the action menu itself sits behind the keyboard: only «Ответить» peeks above
it, the rest is unreachable. The keyboard has to go down when the context menu
opens — the composer keeps its draft — or the menu has to lay itself out above
the keyboard's frame.
Closed by c5c0ab4: the overlay sends the keyboard down as it opens
(`window.endEditing`), so the card lays out against the full screen; the draft
stays in the composer. Verified live on a simulator with the keyboard up:
all seven actions on screen, the draft intact after the menu closes
(`docs/qa/runs/2026-08-19-longpress-run.md`).

### The lifted bubble doubles its shape in the context menu
Reported 2026-08-19 from the device, with a screenshot. In the opened context
menu the bubble is drawn twice: behind the lifted copy a second outline sticks
out, offset up and left, with its own tail — the overlay snapshot and the bubble
it was taken from disagree on frame or scale. The lift starts from the pressed
state at 0.96 (`14c3a0a`), so the likely spot is the snapshot taken at the
presentation layer's scale but laid out at the identity frame, or the original
left visible under the overlay. Seen together with the keyboard defect above, in
the same long-press.
Closed by c5c0ab4: it was the original left visible under the overlay — the
scrim's gradient is transparent at the focus, and whenever the snapshot moved
away from the origin (with the keyboard up it always does) the source bubble
read through the blur as a second outline. The overlay now hides the source
bubble for its lifetime and returns the snapshot to the bubble's current frame
on dismissal, since the feed relayouts underneath when the keyboard leaves.

### The «ack precedes push» smoke check races within milliseconds
Seen 2026-08-19 in a gate run on `run-longpress` (server code untouched by the
branch), not reported from outside. `smoke.mjs` check 21 asserts the sender's
`sent` frame arrives before the push request reaches the APNs mock, comparing
receive timestamps at the test process; one run out of three had the push 2 ms
earlier (`ack 1787167581274 push 1787167581272`) and failed the gate. The
1500 ms hold on the mock delays its response, not the request's arrival, so
when the DO fires the ack and the push concurrently the arrival order within
a few milliseconds is host scheduling, not the product. The check either needs
the mock to stamp after the hold, or a tolerance the size of the real claim
(«the ack does not wait 1.5 s for APNs»), decided on the server side.

### A pin frame stood in the fanout queue for 235 seconds
Seen 2026-08-19 in the live run on `run-pin`, not reported from outside. The
server delivered the pin's chat frame after 235 s in the queue, and the second
device was still on its previous seq. It belongs with the two entries above: the
queue in `ConversationDO` is the one place all three symptoms pass through, and it
gives up on a frame after three attempts with pauses of 200 ms and 1 s
(`FANOUT_MAX_ATTEMPTS`) — after which nothing is retried and the client only
recovers by asking for the range on its next catch-up. Measure the queue itself
before touching the paths around it.

### Typing in the chat input misbehaves under load
Reported 2026-08-19. Hard to catch: when the app stutters, letters appear with
a delay, the input's resize lags behind, and sometimes the caret ends up not
at the end but behind the just-typed text. Smells like the state round-trip
writing text back into the field under lag (an echo write racing fast typing
resets the caret) plus per-keystroke work on the main thread. Needs a
reproduction under artificial main-thread load first.

### Impersonation by display name, and a freed username taken instantly
Raised 2026-08-19 while answering whether a stranger can register someone
else's username (they cannot: `[a-zA-Z0-9_]{3,32}`, UNIQUE COLLATE NOCASE,
the race resolved by the index). What remains: the display name is free text —
three accounts named «Akuz» differ only by the small @handle in search — and a
renamed account's old username is up for grabs the same second, so whoever
watches it inherits the searches for @oldname. Worth deciding: highlight the
@handle in search, a cool-down before a freed name re-enters circulation.

### Interaction smoothness below Telegram
Reported 2026-08-18. Overall animation quality and frame pacing feel worse
than Telegram across the app. Umbrella item; closes on the owner's judgement,
not on a single fix. Measured so far (bubbleanim run, merged 14c3a0a): no
frame over 36 ms in the reaction windows, `feed.ui.apply` ≤ 3 ms.

## Closed

### Unread counts must work offline, and the read must reach the server later
Reported 2026-08-19. Closed by the live run in
`runs/2026-08-19-offlineread-run.md`, no code change: 5 unread accumulated on
the chat list, the stand was killed, opening the chat dropped the counter to 0
with no network, and after the stand returned the sender's messages went to
read ticks with no unread resurrection on the reader after sync.

### Unread count inflated in group chats
Reported 2026-08-19. Reproduced by a red server-smoke check before any product
change: with one unread message, a service frame and a second message, the
push badge said 3 where the reader had two messages to open (d09b138); the
device row inflated the same way (`UnreadCountTests`). Fixed by counting
unread in content rather than in seqs — the server keeps a running content
count stored on every message (8eb1899), the device counts only frames that
take the chat further than it has ever been (d36f0cc). Merged in e4f1ea0,
gate green.

### Bubble resize on a reaction change is not animated
Reported 2026-08-18. Closed in 14c3a0a: `refreshItem` reconfigures the visible
cell inside a 0.35 s spring with `performBatchUpdates` in the same animation —
the bubble grows in place, neighbours slide, contentOffset holds; reaction
capsules are reused per emoji, media survives without a BlurHash flash. The
width-only inline-reaction case animates too. Frame-by-frame evidence in
docs/qa/runs/2026-08-19-bubbleanim/.

### Long-press on a bubble has no animation
Reported 2026-08-18. Closed in 14c3a0a: a 0.1 s press dips the bubble to 0.96,
a 12 pt finger move releases it (scroll unaffected), and the context menu
lifts from the pressed state — the overlay snapshot starts at the presentation
layer's current scale, so the touch flows into the lift without a seam.

### Read tick colour invisible, single tick oversized
Reported 2026-08-18. Closed by 95c03a3: the read tick got its own hue per
theme, the single tick the same glyph size as one of the pair.

### Back button in the chat header oversized
Reported 2026-08-18 (third time). Closed by 95c03a3: the custom button now
draws the system chevron at the system size, kept only for the `chat.back`
accessibility identifier; the header title sits on a capsule ground.
