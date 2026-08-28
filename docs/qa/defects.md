# Defect log

Defects reported by the owner, one entry each. An entry stays until the fix is
merged and the owner's scenario was re-run; then it moves to the closed list
with the commit that closed it.

## Open

### The server smoke test fails on push timing, on a different check per run
Found 2026-08-28 by the gate after the shader-messages merge
(`.claude/gates/main-shader.log`): `no push for own echo` was red on the
gate's throwaway stand. On a second throwaway stand (`wrangler dev --port
8811`, a fresh persist dir with the migrations applied) that check passed and
`cmid swept behind the sender's ack` failed instead, with the same code:
neither merge touched `server/`. Both checks wait for a push or an alarm with
a fixed timeout, so a loaded host is the first suspect, but two different
checks red on two stands is not yet shown to be the host. To investigate:
run the smoke test alone on an idle host, and if it stays red, read the
push and alarm timings the DO logs against the timeouts the test uses.

### An own service frame drags myReadUpTo over the peer's unread messages
Found 2026-08-28 in passing while verifying the in-chat mention counter: the
«Design» fixture chat sat at `myReadUpTo = lastSeq = 123` with
`unreadCount = 20`. `advanceChat` let a service frame advance `myReadUpTo` when
the frame was the reader's own (`isOwn OR myReadUpTo >= seq - 1`), so an own
sender-key handout or reaction echo arriving after the peer's unread content
marked all of it read — the unread count stayed, the cursor lied, and
everything built on the cursor (the mention mark, the mention counter, read
receipts derived from `myReadUpTo`) saw a fully-read chat.
Two writers did it: `advanceChat` let any own service frame advance the
cursor (`isOwn OR myReadUpTo >= seq - 1`), and the sent-ack path stamped
`myReadUpTo = MAX(myReadUpTo, seq)` for every own ack — including the acks of
rowless service frames (the fixture chat had no message row at any of the
swallowed seqs).
Closed in the same change: only a contiguous read may swallow a service seq in
`advanceChat` (`testOwnServiceFrameDoesNotSwallowForeignUnread` and its
fully-read counterpart hold both sides), and the sent ack moves the cursor
only when the send has a message row — a send the reader actually saw.

### «Сообщение ещё не загружено» placeholders pile up in the fixture group
Seen 2026-08-28 in the «Design» fixture chat: twenty identical placeholders
filling a screen between two content messages. Measured on the device
database: the 616-seq hole between the two messages holds 323 unreadable seqs
that are not contiguous — the numbers in between were never recorded as gaps —
and the feed made one placeholder per contiguous run, about ninety of them.
Closed by 37841a3: a hole between two messages of the feed is one placeholder
carrying the number of messages behind it
(`testHoleBrokenBySkippedSeqsIsStillOnePlaceholder`).
Open underneath it: the repair protocol recurses without a ceiling once a
pairwise session is broken past healing. Watched over 2026-08-28 on the alfa
fixture against the bravo CLI: 443 unopenable envelopes grew to 908 and then
to 2575 (`no_session`), in bursts of 200–400 a minute that coincide exactly
with each `msngrfixture send --as bravo` run — the CLI's first run even timed
out with «waiting for the messages to leave the outbox», its queue stuffed
with repair replies. The cycle: alfa's repair requests wait for the sender;
the CLI comes online and answers every one with a `repair` copy; each copy
takes a fresh seq, fails to open in the same broken session, and earns its
own repairRequest with a full budget of 5 attempts — so every answered wave
seeds the next, bigger one. `resetPairwiseSession` does not stop it: the
session is rebuilt per request while the answering side keeps encrypting into
its own fork. The cycle is broken from both ends in 24d0dc6 and 8cff769: the answering
side gives no repair copy of a repair frame
(`testSenderDoesNotAnswerRepairForARepairFrame`), and the asking side lets at
most 20 unanswered repairs stand per sender before new requests wait
(`testRepairCeilingHoldsNewRequestsBack`). The pile already accumulated in
the alfa fixture stays as history holes. Watched live over the server stand:
the fixed CLI's first run answered the standing backlog once (Design lastSeq
12159 → 12649), and its second run added zero — the wave no longer seeds the
next one. Why the original
session forked is still unestablished (one fixture home driven by two
processes remains the best-fitting shape).

The ceiling deadlocked itself a day later, seen 2026-08-29 on the same
fixture: 2515 of bravo's pending rows had spent all 5 attempts, the in-flight
count took them as unanswered, and with 2516 ≥ 20 not one of the 421
never-asked rows could send its first request — repair to that peer was dead
until the envelopes expire a week on. Held live for a 240 s window with the
bravo CLI online: pendingDecrypt stayed at 2937 exactly. Fixed in 5707283:
a row with spent attempts is not in flight
(`testSpentRepairsDoNotHoldTheCeilingShut`).

### A service storm in one chat stalls the whole sync
Observed by another agent 2026-08-28 on the alfa fixture home while the
repair avalanche (above) stood in the queue: bravo↔alfa `syncedSeq` froze at
2576 with `lastSeq` 3215, the app answered repair requests for the flooded
group at about one per 6 seconds, and even a brand-new chat from a fresh
account stayed at 3/0 — the backlog of one chat's service frames starved
every other chat's catch-up. The avalanche itself is closed (24d0dc6,
8cff769); left open here: the per-frame cost and the fairness. Read from the
code (not yet measured): every incoming repairRequest with a session reason
marks the pairwise session for a rebuild (`resetPairwiseSession`), so each
answer's `encryptPairwise` misses the session, fetches a fresh prekey bundle
over the network, runs X3DH under the CryptoGate flock and only then sends —
one network round-trip per frame over the tunnel is the right order for the
observed ~6 s. Candidates: collapse the resets (one rebuild per peer per
window instead of per request), answer a batch under one session, and drain
chats fairly so one chat's backlog does not starve the rest.

Seen again 2026-08-29 on the same home: bravo↔alfa `syncedSeq` frozen at 3958
with `lastSeq` 4569 while the app sat foreground for over ten minutes — a
message sent to alfa during that window never arrived even as an envelope
(`pendingDecrypt` tops out at seq 3965), so the starvation covers live
delivery of the same chat, not only other chats' catch-up.

### A severed pairwise session never heals: both sides ask, neither answer arrives
Found 2026-08-29 while walking the repair debt on the alfa fixture. The
alfa↔bravo pair is broken symmetrically: alfa holds 2937 of bravo's envelopes
(`no_session`), and bravo's own home holds 2947 of alfa's (`no_session`) plus
221 `pk_decrypt_failed` — alfa's repair requests, sent over what alfa believes
is a fresh X3DH, arrive at bravo as prekey envelopes bravo cannot open. That
shape means the prekey bundles the server hands out for bravo no longer match
the private halves in bravo's store (the fixture-home fork again), so every
new session either side builds is stillborn, and all five repair attempts per
message were spent into the void while the peer was genuinely online. The
engine has no move for this state: `replenishPrekeysIfNeeded` only tops up
the one-time count, nothing republishes the signed prekey or drops the
poisoned one-times when the device's own `pk_decrypt_failed` keeps repeating.
A device that repeatedly fails to open prekey envelopes addressed to it holds
the strongest possible signal that its published bundle is stale — republishing
identity and prekeys at that point is the missing self-heal. Until then the
alfa↔bravo fixture pair cannot exchange new readable messages at all.

### A silent identity rotation is not re-checked by TOFU while a device list is cached
Found 2026-08-27 in passing during the multi-device TOFU run
(qa/runs/2026-08-27-multidevice-tofu-run.md). `/keys-update` (the identity
heal endpoint) overwrites a device's `ik:` record but does not bump
`devicesVersion` and broadcasts nothing. A peer that has already cached the
device set holds the old signing key; the per-send TOFU check reads that
cached key, finds it trusted, and never refetches. So a device that rotates
its identity after a peer cached it is not caught until the cache drops for an
unrelated reason (a genuine link/revoke, or a reconnect where the version did
change). Reachability is behind preconditions — a warmed cache and an existing
session, since a fresh session pulls a prekey bundle and would compare — so
this was a gap, not a confirmed break. Closed: `/keys-update` now bumps
`devicesVersion` and broadcasts the change the way revoke and linking do, so
peers drop the cached set and the per-send TOFU check reads the rotated key
(smoke `identity heal bumped the device-set version`, `the rotated key is
what peers now read`).

### A read message's own banner shows over the open chat and stays in the shade
Found 2026-08-27 during the notification-withdraw run
(qa/runs/2026-08-27-notification-withdraw-run.md). A message arrived over the
socket while the app sat in the background with the chat open behind it; the
app posted its local notification, as designed for the background. On
returning to the foreground the banner presented over the very chat that
already showed the message, and after the message was read the notification
was still in the shade a minute later, alone — the pushed stack around it was
withdrawn correctly. Both halves closed in code: `shouldPresentSystemPush` now declines a local
banner too when its chat is open or its message is read (the isLocal bypass
kept only against the self-dedup — NotificationDecisionTests, the two
own-local suppression cases), and the local-notification `add` re-runs
`dropReadNotifications` after it lands, closing the race with the read's
sweep. A live pass was attempted 2026-08-29 on the alfa fixture and came back
inconclusive for this defect: the message from bravo never reached the feed
at all (the severed alfa↔bravo pair, its own entry above), so no notification
existed to present or withdraw — nothing showed over the open chat and the
shade stayed empty, but that proves delivery was broken, not that the banner
logic held. The live pass is still owed, on a chat pair whose sessions work.

### A held swipe on a chat row stutters
Reported by the owner 2026-08-27: swiping a row sideways in the chat list
with the finger kept on the screen, the row's motion is badly jerky. The list
has two horizontal gestures over the same rows, the row's swipe actions and
the folder-tab pager, so the first thing to look at is the two of them
fighting for the touch. On the simulator a synthetic 2.5 s drag from `idb`
moved the row evenly, with and without the pager gesture (recorded at
~48 fps, the row advanced ~3 pt per frame throughout); the owner confirmed
that recording looks smooth. A real finger differs in two ways the driver
cannot fake, vertical jitter and touch-event cadence, so the next step is a
screen recording from the device.

### The in-app banner does not react to a tap
Reported 2026-08-19 from the device. Tapping the in-app notification banner does
nothing; it has to open the chat it announces. The tap-opens-chat path exists and
was checked on the simulator (push-client/inapp-banner-tap-open-chat), so either
the hit area or a gesture conflict kills it on the device — same family as the
row hit areas below.

Worked on 2026-08-20 without a reproduction on the simulator, where the banner
answers taps under the old geometry as well. What the old geometry did leave
open, and what is closed now: the window was placed at a top inset read from
`scene.windows.first` — not necessarily this window — and was only as tall as
the measured content, while the content then laid itself out below its own safe
area. Any disagreement between that inset and the real one put the banner partly
below the window's edge, where it stays visible (a window does not clip) and
takes no touches. The banner now lays out from the window's own top edge
(`safeAreaRegions = []`) and the window is placed at the inset it reports
itself, so the content and the band are the same height.
`InAppBannerWindowTests` holds it: what takes the touch is inside the window, the
band stays in the top half, and the content fills exactly the band it was
measured for. A full-screen window with a hit-test passthrough was tried first
and reverted — SwiftUI's hosting view claims every touch inside its bounds, so
that window made the whole app untouchable, which the same tests caught.

A harness for the live side exists since 2026-08-20: `LivePeerDriverTests` in MsngrKit
registers a peer, keeps it in `MSNGR_PEER_HOME` so the next run is the same
person writing again, and sends a real encrypted message to the username in
`MSNGR_PEER_TO` — which is what the app needs to raise a banner at all. Using
it, one message from a fresh peer landed while the app stood on another chat's
screen and no banner showed in 60 frames sampled over 30 s; the message itself
arrived (its row is in the list). That is not yet proof — the run cannot tell
whether the app got that particular frame — so the next step is to read the
app's own view of it, and only then look at the window geometry of the banner
(its `UIHostingController` takes a top safe-area inset inside a window that is
only as tall as the measured content, which would push the visible banner below
the window's own bounds, where touches do not reach it).

### Impersonation by display name, and a freed username taken instantly
Raised 2026-08-19 while answering whether a stranger can register someone
else's username (they cannot: `[a-zA-Z0-9_]{3,32}`, UNIQUE COLLATE NOCASE,
the race resolved by the index). What remains: the display name is free text —
three accounts named «Akuz» differ only by the small @handle in search — and a
renamed account's old username is up for grabs the same second, so whoever
watches it inherits the searches for @oldname. Worth deciding: highlight the
@handle in search, a cool-down before a freed name re-enters circulation.

### A chat climbs the list with no new message in it
Seen 2026-08-27 while recording the README demo on the simulator (alfa
fixture). After a ❤️ reaction was put on a message in «Standup», the row moved
from fifth to second place, above chats whose last message was hours newer;
its own time label kept saying 21.08.26. Earlier the same session «Design»
rose above «Bravo Service» while showing «Сообщение ещё не загружено» as its
last row, again with no content message of its own. The list is ordered by
`chat.lastActivityAt`.
The reaction case is closed: `applySentAck` stamped `lastActivityAt`
unconditionally on every own ack — a reaction, an edit, a repair answer all
lifted the chat — and now stamps it only for a send with a message row
(`testAServiceAckDoesNotLiftTheChat`). Live on the alfa fixture: a 👍 put on
a message in «Standup» landed on the bubble while the row stayed in place
and its `lastActivityAt` kept its old timestamp. The «Design» sighting fits the same
write (the repair answers the fixture kept acking), with one alternative
still open: an incoming unreadable envelope also moves `lastActivityAt`,
which is arguably right — it is a real message, merely unreadable yet.

### A row moving up the chat list flies through the rows above it
Seen 2026-08-27 in the README demo recording (simulator, alfa fixture). When a
message from «Charlie Service» lifted its row from the bottom to second place,
the row travelled over the others in about 170 ms with nothing clipping it:
for four or five frames its title and preview were drawn on top of «Bravo
Service» and «Standup», and the rows it passed shifted down under it while
the move was still going. The owner's word for the result: crooked. The list
now moves in `Theme.spring` (0.45 s) instead of `springFast`; in the re-run of
2026-08-27 the lifted row started below the screen, so the crossing itself was
not exercised — to be watched on the next lift of an on-screen row.

### A new request appears in the list with no animation
Seen 2026-08-27 in the same recording. When a stranger's first message
arrived, the «Заявки на переписку» header and the row appeared in a single
frame, with the rows below jumping down to make room; the avatar of the new
row showed «…» for a frame before the initials came. The list model animated
only a change in the visible chats, not in the requests; the same change now
runs in the spring transaction as well (the re-run on 2026-08-27 shows the
header and the row easing in). The «…» avatar frame is still open.

### Accepting a request ends with no animation
Asked for by the owner 2026-08-27 while reviewing the demo: after «Принять»
on the request screen the closed-eye placeholder and the two buttons are
replaced by the chat in a cut. The owner wants a transition here, a dissolve
(«dust») or something of that kind. Done the same day: the card leaves through
`AnyTransition.dissolve` (blur, a slight swell, fade) and the feed fades in,
both in one `Theme.spring` transaction; the flag flips in the model on the
tap, ahead of the database row. Waiting for the owner's look.

### A group shows «Сообщение ещё не загружено» that never resolves
Seen 2026-08-27 on the alfa fixture in the «Design» group: a placeholder row
under the system lines, still there a minute later with the socket up.
Explained 2026-08-28 while working the repair avalanche (see the placeholder
entry above): the seqs under it are envelopes no replay opens — seq 8 and 12
are `not_addressed` handouts from the re-registered old identities, the rest
`no_session`/`pk_decrypt_failed` with the repair attempts spent and the
sending CLI not online to answer. «Never resolves» is that entry's closed
mechanics, not a separate defect; the feed now shows such a hole as one line
with the count (37841a3).

### Interaction smoothness below Telegram
Reported 2026-08-18. Overall animation quality and frame pacing feel worse
than Telegram across the app. Umbrella item; closes on the owner's judgement,
not on a single fix. Measured so far (bubbleanim run, merged d4f58f5): no
frame over 36 ms in the reaction windows, `feed.ui.apply` ≤ 3 ms.

## Closed

### An edit's envelope failed to open on the peer with no_session
Seen in passing 2026-08-21 during the unread-recount run and reproduced on
demand 2026-08-27: an edit's seq sat in `pendingDecrypt` and `historyGap` as
`no_session` with repair attempts counting up, the contiguous prefix stalled
behind it. The repro pinned the failing frame as a `dr` box the peer could
place in no live or archived chain; the repair protocol could not recover it
because the sender rebuilt its answer from the `message` row under the asked
seq, and an edit has no row of its own — every attempt ended in "we do not
hold". Closed 2026-08-27: the ack of a service frame now records its payload
under the assigned seq (`sentServiceFrame`, the target resolved to its seq),
and a repair request for a seq with no message row is answered from that
record. Live: with bravo's session to alfa deleted, seqs 18–20 (a message and
two edits) went `no_session` and healed once the 60 s repair grace ran out — the
message by its row, the edits by their records
(qa/runs/2026-08-27-service-frame-repair-run; MessageRepairTests units on
both sides). Frames acked by builds without the record stay unrecoverable
(the repro's seqs 9 and 11); why the sending chain diverged during that churn
was not established.

### The unread banner says 56 with a thousand unread
Reported by the owner 2026-08-21 near midnight, with a screenshot from the
device: after a ~1000-message burst the feed's unread banner read «56 unread
messages» while the scroll-down badge next to it said 1004. Reproduced on
demand 2026-08-27: with 700 planted, 300 more caught up into the open chat
and the banner still read 700 (the database held 1000 incoming at or after
the anchor). The banner grew in `countIncoming` over the feed observation's
window snapshots, and a message that never enters the window — everything a
catch-up appends while the reader stands in history, and most of a coalesced
burst — was never counted.
Closed the same day: the count is derived, not incremented. Whenever the chat
row's `lastSeq` moves past what was last derived, the database is asked how
many incoming messages stand at or after the anchor, and the return from the
background plants the banner from the same kind of query
(`ChatViewModel.reconcileUnreadMarker` / `restoreMarkerAfterObscured`,
`UnreadMarkerState.reconcile` / `plant`). The staged rerun showed the banner
follow the truth, 600 → 900 (qa/runs/2026-08-27-unread-banner-run.md);
`UnreadMarkerStateTests` covers the rules and the queries.

### A new reaction capsule reveals a clipped emoji instead of springing in whole
Reported by the owner 2026-08-27 («плохо», frames from the capsule-appearance
recording). While the capsule sprang in, the plate stood at nearly full size
and the emoji showed as a growing sliver cut from its top left corner — a
reveal, not a scale. The capsule was created with a zero frame,
`configure(animateIn:)` started the spring first, and the frame landed after;
the label picked its bounds up in a layout pass that ran inside the feed's
outer animation block, so `label.frame` animated from zero and clipped the
glyph.
Closed the same day: the capsule's frame and its label are laid out inside
`performWithoutAnimation` before the entrance spring starts, so the whole
capsule scales as one unit. `testNewCapsuleLabelIsLaidOutBeforeTheSpring`
fails on the old order and passes on the new one; the re-recorded entrance
shows the glyph whole in every frame, and the owner confirmed the look
(«анимация теперь выглядит совсем иначе»).

### The viewer's close button does nothing over a video
Found in passing 2026-08-27 in the viewer run: on a video page the tap on ✕
went to the system player's picture-in-picture glyph, which sits in the same
corner, and the viewer stayed open. Closed by a423462: the video page is the
player controller with picture-in-picture off; ✕ closes a photo and a video
page alike (`docs/qa/runs/2026-08-27-viewer-run.md`).

### A video neither joins the album grid nor appears the moment it is sent
Reported by the owner 2026-08-27: several videos picked together are sent one
by one instead of as a mosaic, and a video does not show up in the chat until
its preparation is done; the owner also asked for a loader with the percent.
`sendPicked` split the pick into photos (one album) and videos (a bubble
each), and a video's row was written only after `loadTransferable` had copied
the file out of the library.
Closed by 987bb8c: one pick is one message with a typed placeholder per slot
before any loading, videos share the mosaic, and every tile carries a ring
with the percent of the transcode and the upload until the ack. Verified live
with two ffmpeg clips and a still (`docs/qa/runs/2026-08-27-video-album-run.md`).

### Voice bubbles look unkempt
Reported by the owner 2026-08-27 with a screenshot from the device: the voice
plate is twice the height of a text bubble, the waveform sits at the very top
and the duration hangs in the middle of empty space, one duration reads «0:…»,
and every waveform is a flat row of dots whatever was said. The plate's height
follows the text size (`attachmentHeight`, 42 to 78 pt) while
`VoiceMessageView.layoutSubviews` placed the wave and the label at fixed
offsets for the 42 pt plate; the duration label was capped at 60 pt, which a
scaled 11 pt font overflows on «0:00,5»; the amplitudes were normalised to the
loudest peak, so a single click flattened the speech around it.
Closed by 126a8a3: the plate lays itself out from its height, the label is as
wide as its text, loudness is the RMS per bucket scaled to the 95th
percentile. The same run found the feed measuring at the default text size on
a cold start under text drawn at the reader's; the snapshot now follows the
scene's traits. Reproduced and re-run at accessibility XXXL on the simulator
(`docs/qa/runs/2026-08-27-info-screen-and-voice-run.md`); a spoken take on
the device is the owner's to look at.

### An animated GIF plays as a single frame
Reported by the owner 2026-08-21, late evening: a GIF sent into a chat showed
one static frame. The animation was lost on the way out — every picked image
went through the JPEG pass, and JPEG holds one frame.
Closed by 2cfd65c: a multi-frame GIF is sent as its own bytes with `image/gif`
as the mime, the feed plays it in the tile a still would have filled (frame
delays read from the file, one decoded frame at a time, stopped with the cell
and paused off-screen through the same switch the video autoplay uses), and the
full-screen viewer plays it too instead of showing the first frame. Verified
live on a simulator of its own: the feed strip differs across frames 0.6 s
apart and the viewer differs across four frames 0.5 s apart
(`docs/qa/runs/2026-08-21-gif-run.md`).

### A received PDF does not open for viewing
Reported by the owner 2026-08-21, late evening, with a screenshot: tapping the
98.9 MB «HISTORY.pdf» seemed to do nothing. Reproduced on the cold path while
the host carried a parallel gate build: about sixty seconds of complete
silence between the tap and the previewer — the download and decrypt of
98.9 MB with no indicator of any kind — after which the PDF did open, all
642 pages. On a quiet host the same cold open takes about two seconds. Closed
in the same change: the tap shows a spinner plate for as long as the fetch
runs, and a second tap joins the running fetch instead of starting another
(qa/runs/2026-08-21-file-preview).

### The unread count inflates across an offline gap
Found 2026-08-21 by a live check: a peer who was offline while the other side
sent two messages, deleted one for everyone and edited the other came back to
`unreadCount = 3` with exactly one readable new message — the snapshot
estimates unread as `lastSeq − myReadUpTo`, and the service frames and the
tombstone behind those seqs counted as messages. Closed in the same change:
once a chat's contiguous prefix is complete the number is recounted from the
rows — incoming, not system, not deleted, plus envelopes still waiting for a
key (`SyncEngine.recountUnread`, called from the snapshot and at the end of a
chat's catch-up; UnreadRecountTests hold the three shapes). A chat still
behind keeps the estimate.

### An XCUITest tap on the locked-recording send button fires no action
Found 2026-08-21 by the uicheck on main: `VoiceTests.testG_PlaybackSurvivesAnotherChat`
failed twice in a row at `sendVoice`, with the synthesized event landing on the
button's centre and the recording timer walking on past it.
Chased on 2026-08-21 over ten runs of G on a simulator of its own. The tap
itself never went missing again; what the runs did find was two locators and
one host gap, all of them reading as a lost tap from the outside:

- The device had lost its microphone grant (an `uninstall` takes it with it), so
  every frame of the press-and-drag asked for access again, got a refusal, and
  put the gesture back to idle — the take never locked and no send button ever
  appeared. `scripts/fixture.py grant` is what the run was missing.
- The pause state was matched by the English label `label == 'Pause'`, and the
  app translates it — «Пауза» on a ru host, so the run could never see a
  message playing. The speed assertions compared «Speed 1,5×» the same way.
- The new chat sheet's field was matched by its localised placeholder (its own
  closed entry above).

Closed by 2154fba: the play button carries the state in its identifier
(`voice.play` / `voice.pause`) and the speed rides in the element's value,
while the translated labels stay for the reader. The product was right
throughout — checked by hand with a 62 s and a 26 s take: after the walk out to
the list and back the bubble shows pause and the position keeps advancing, and
the only stops the player logs are its own `play` and the end of the take.
VoiceTests green whole afterwards, 13 of 13, three consecutive runs of G before
that.

### The time in a chat list row jumps when the preview's line count changes
Reported by the owner on 2026-08-21 while watching the reorder run: a preview
that wraps to a second line (or unwraps back) resizes the row, the vertically
centered content rides the resize, and the cross-fade paints two time labels a
few points apart. Closed in this change: the preview reserves two lines
whether the text fills them or not, so the row's height never depends on the
line count. Verified live in both directions — the neighbouring row and the
time label hold still, the preview cross-fades in place
(qa/runs/2026-08-21-chatlist-reorder, strips 04–06).

### The block button on a request has no contrast in the dark appearance
Seen in passing on 2026-08-20: on the request screen «Заблокировать» is a
`.bordered` destructive button, but the app's accent tint painted it, so on
the dark ground it read as orange letters on dark brown. Closed by `ab89288`:
the button carries its own `.tint(.red)`, and a destructive action no longer
inherits the accent. Verified live on 2026-08-21 in the dark appearance — a
fresh peer's message request shows the block button in red over its own dark
red ground. If the owner prefers the accent there after all, the tint is one
line to take back.

### List rows are tappable only on their letters and icons
Reported 2026-08-19 from the device: in many lists the tap worked only exactly
on the text or the icon. The first pass (`91d6bb7`) gave the chat-list and
new-chat rows a content shape and was verified live the same day. The sweep of
2026-08-21 (`3b9f942`) read every `buttonStyle(.plain)` in the app and found
three more instances: the folder tabs and the manage chip (`ChatFolderBar`,
transparent padding without a content shape), the forward picker rows
(`ForwardPickerView`, content-hugging label), and the pin pad's del/face keys
(`Color.clear` is not hit-testable; the empty face key with biometrics off is
disabled now rather than a dead zone). Verified live on a fixture simulator:
a tap on the manage chip's padding opens the folders screen, a tap on the far
right of a forward-picker row picks the chat and the forward lands. Settings,
folders, chat info and the search results go through List buttons and
NavigationLinks or already state their shape.

### A forwarded message deleted for everyone keeps its forward line
Found 2026-08-21 during the reactions/forward run, out of its scope: deletion
cleared text and media but left the `forward` column, and the layout kept
drawing the header row above «Сообщение удалено» (seen live in the alfa–bravo
direct chat, docs/qa/runs/2026-08-21-reactions-forward/, the deleted album).
Closed by `fc55c81`: a message deleted for everyone lays out neither the
forward line nor the reply strip. Verified live the same day — a forward into
the Standup group deleted for everyone renders as a bare one-line tombstone.

### The «ack precedes push» smoke check races within milliseconds
Seen 2026-08-19 in a gate run on `run-longpress` (server code untouched by the
branch): `smoke.mjs` check 21 asserted the sender's `sent` frame arrives before
the push request reaches the APNs mock, and one run out of three had the push
2 ms earlier — host scheduling over an ordering the design never promises,
since the push queue is independent of the ack path. Closed in 840f2ea: the
check now asserts the real claim — the ack does not wait out the mock's
1500 ms hold (`h1.at - hp1.at < 1000`) — and the quiet rerun was green whole
(259/259).

### A pin frame stood in the fanout queue for 235 seconds
Seen 2026-08-19 in the live run on `run-pin`: the server delivered the pin's
chat frame after 235 s, because the fanout gave up on a frame after three
attempts (`FANOUT_MAX_ATTEMPTS`) and nothing was retried after that. The
mechanism died with run-delivery: a `DeliveryRecord` per recipient lives until
acknowledged and retries on a growing pause with no attempt cap
(`ConversationDO.pumpUser`), so a frame can be late but can no longer be
abandoned. Live numbers in `runs/2026-08-19-delivery-run.md` — a 100-burst
lands in 255 ms with every tick following.

### A SyncEngine started again after stop() never drains the outbox
Found 2026-08-21 on the run-devices branch, in a test that restarted the
engine. The outbox and action loops iterate `AsyncStream`s created once at
init; cancelling their tasks in `stop()` ends those streams, so a second
`start()` subscribes to streams that are already over and every wakeup after
that is lost — a send enqueues and sits in the outbox forever. No app path
restarts an engine today (bootstrap always builds a fresh one), so nothing
user-visible. Fixed in passing on the same branch: `start()` recreates the
wakeup streams.

### Unread counts must work offline, and the read must reach the server later
Reported 2026-08-19. Closed by the live run in
`runs/2026-08-19-offlineread-run.md`, no code change: 5 unread accumulated on
the chat list, the stand was killed, opening the chat dropped the counter to 0
with no network, and after the stand returned the sender's messages went to
read ticks with no unread resurrection on the reader after sync.

### Unread count inflated in group chats
Reported 2026-08-19. Reproduced by a red server-smoke check before any product
change: with one unread message, a service frame and a second message, the
push badge said 3 where the reader had two messages to open (100af30); the
device row inflated the same way (`UnreadCountTests`). Fixed by counting
unread in content rather than in seqs — the server keeps a running content
count stored on every message (5d5763f), the device counts only frames that
take the chat further than it has ever been (06f9359). Merged in 4356910,
gate green.

### Bubble resize on a reaction change is not animated
Reported 2026-08-18. Closed in d4f58f5: `refreshItem` reconfigures the visible
cell inside a 0.35 s spring with `performBatchUpdates` in the same animation —
the bubble grows in place, neighbours slide, contentOffset holds; reaction
capsules are reused per emoji, media survives without a BlurHash flash. The
width-only inline-reaction case animates too. Frame-by-frame evidence in
docs/qa/runs/2026-08-19-bubbleanim/.

### Long-press on a bubble has no animation
Reported 2026-08-18. Closed in d4f58f5: a 0.1 s press dips the bubble to 0.96,
a 12 pt finger move releases it (scroll unaffected), and the context menu
lifts from the pressed state — the overlay snapshot starts at the presentation
layer's current scale, so the touch flows into the lift without a seam.

### Read tick colour invisible, single tick oversized
Reported 2026-08-18. Closed by 84467d5: the read tick got its own hue per
theme, the single tick the same glyph size as one of the pair.

### Back button in the chat header oversized
Reported 2026-08-18 (third time). Closed by 84467d5: the custom button now
draws the system chevron at the system size, kept only for the `chat.back`
accessibility identifier; the header title sits on a capsule ground.

### A search result in "Новый чат" does not open a chat
Found 2026-08-20 while running the pin-depth scenario (`run-pin` branch),
unrelated to that change. Tapping a row under "Глобальный поиск" in
`NewChatView` — confirmed against the row's own accessibility frame, not a
guessed coordinate, and confirmed live via `curl .../api/chats` before and
after the tap — does nothing: no `POST /api/chats` reaches the server, no
local `chat` row appears, the screen stays as it was. Reproduced independently
on two simulators, against freshly registered accounts with signed identity
keys.

Closed the same evening: this is the row hit area, not the Task. The row of
`NewChatView` carried no shape of its own, so only its letters and avatar
answered a touch — a tap aimed at the centre of the row's frame landed in the
gap beside the name and did nothing, which is exactly what the run saw. The pin
run was built from main as of the night before and did not have `91d6bb7`, where
the row states `contentShape(Rectangle())`. Verified on the shared stand with a
build that has it: a peer registered a minute earlier, no chat between us,
searched in «Новый чат», one tap on the row — the chat opened.

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

Under that, a permanent one: the identity binding merged in `f28c27f` added
`identity_key_sig` with `DEFAULT ''`, and on the stand 2357 of 2360 rows in
`identity_keys` carry that empty default. A client refuses a bundle without the
signature (`newSessionBox` returns nil), so every device of the recipient stayed
without a box and the envelope went out addressed to nobody — the sender saw a
sent message that reached no one. Fixed on both ends: the send now fails with
`noUsableKeys` when no device of a recipient could be encrypted to, so the outbox
keeps the message; and `POST /api/identity` lets a device publish its own binding,
which `SyncEngine` does once per start, so an account older than the signature
heals itself. Re-run through probe-send.mjs green on both paths.

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
land on the recipient one per second. Statuses are the owner's bar here too:
the tail of a burst must not trail behind by a minute and a half.

Measured and fixed on run-delivery (`runs/2026-08-19-delivery-run.md`): the
second per message was the APNs call awaited inside `UserSessionDO./event`,
serialized by the chat's head-of-line queue — the arrival gap tracked the push
latency one for one (157 ms at a 150 ms mock, 1 008 ms at 1 s). With the push
moved to its own queue a burst of 100 lands in 255 ms, gap p50 0 ms.

### Delivery ticks stop after the first messages of a burst
Reported 2026-08-19 from the device (iPhone 15 Pro Max against the shared
stand). The recipient has all 100 messages of a burst on screen, while the
sender shows the double tick on the first two only — the other 98 keep the
single «sent» tick. The bar the owner set for this: statuses are the hardest
and most important thing in the product and have to be flawless —
WhatsApp-grade, where every tick updates the instant the state changes.

Same root as the burst pace, fixed on run-delivery: the delivered receipts to
the author queued behind the recipient's still-undelivered messages (tick lag
p50 8.1 s on a 100-burst). With one independent delivery chain per recipient a
tick follows its message by p50 31 ms on the wire and within 106 ms between two
live clients (`BurstTicksTests`); the live run shows the whole burst
double-ticked (`runs/2026-08-19-delivery-run.md`).

### A dead APNs endpoint stops chats
Reported 2026-08-19 from the shared stand: with nothing listening on the APNs
port, new messages stopped arriving entirely. The chain: `UserSessionDO./event`
awaits `pushToDevices`, the push retries three times against a dead endpoint,
and the fanout queue of the chat is head-of-line, so one undeliverable push
holds every following frame; the stand had piled up ~20k retried pushes of a
single message by the time the mock came back, and the worker itself wedged
along the way (`Too many open files`, `kj/async-io-unix.c++:918` — the delivery
timeout aborted `/event` after 10 s while its push fetches kept running, and
every retry started three more). The owner's bar, recorded as acceptance: chats
must work with APNs fully down — the socket delivery and the push must not
share a fate.

Done on run-delivery and run live (`runs/2026-08-19-delivery-run.md`): /event
acknowledges at the socket and the push goes through a persisted queue that
retries owed pushes on a growing pause. With nothing on the APNs port, 10
messages landed between two simulators instantly with every tick; when the mock
came back, 111 queued pushes caught up in ~13 s with no repeated banner.
`probe-apns-down.mjs` keeps the scenario runnable. The FD-exhaustion chain dies
with the cause: nothing awaits a push inside a delivery any more, so an aborted
delivery no longer leaves fetches running.

### The chat list bar comes back from a chat washed out
Reported 2026-08-19 from the device, with a screenshot: «темная тема чего-то не
хватает» — the area above the folder tabs blank. Reproduced live on a simulator,
2026-08-20 (`runs/2026-08-20-nav-bar/`), and it has nothing to do with the
palette: open any chat, come back, and the list's navigation bar keeps the
pushed state — no large title at all, and both toolbar glyphs washed out to a
smudge. The same in the light appearance, so the dark theme only made it easier
to see.

Cause and fix, found by elimination on 2026-08-20: the chat replaced the system
back button with a leading item of its own under
`navigationBarBackButtonHidden(true)`, and after such a pop the list's bar
stayed as the pushed screen left it. With the system back button (`881ea3c`)
the title and both glyphs are in place the moment the pop settles, through two
cycles. Re-verified live on 2026-08-21 on current main. The dark appearance
also lost the empty-screen glyph, fixed through a `Theme.decorativeGlyph` role
(`runs/2026-08-20-dark-theme/`); the taste call about the pure-black dark list
carrying none of the palette's identity stays with the owner.

### A row of the chat list answers only on its text
Reported 2026-08-19 as part of «много где не тапабельна область строки списка»,
and reproduced live on 2026-08-20: in the request rows of the chat list a tap at
(175, 305) — inside the row, to the right of the name — did nothing, while
(100, 291) on the name itself opened the chat.

Cause and fix: `ChatRow` carries the navigation in a `NavigationLink` whose
label is an `EmptyView` at `opacity(0)`, so nothing in the row was hit-testable
except the content's own letters and avatar; the same in `NewChatView`'s rows,
where `buttonStyle(.plain)` takes away the cell behaviour a List button would
have had. Both now state `contentShape(Rectangle())` (`91d6bb7`), and a tap at
(300, 305) — the far right of a row — opens the chat. The wider sweep of every
list in the app lives in the open entry above.

### A tap on a found user in «Новый чат» seemed to hang the screen — it did not
Raised 2026-08-20 by the pin run against its own stand and withdrawn the same
evening: its taps were landing beside the result row, which reads exactly like a
screen that ignores them. Checked here independently on the shared stand — both
paths, the chat list's global search and the «Новый чат» sheet, opened the chat
in about two seconds and answered taps throughout. No hang. Kept as an entry
because the aiming mistake has now cost two runs: a tap goes through
`scripts/grid.py <udid> --tap X Y` with the coordinate read off the picture.

What the false alarm did turn up, and what is fixed (`f1a839d`): the sheet's
search fired a request per keystroke, cancelling nothing, so nine letters meant
nine searches whose answers could arrive out of order and an older one could
overwrite the newest results. The search now waits out the typing and cancels
the request in flight, and while a newer query is unanswered the screen no
longer claims «Нет результатов» about it.

### The context menu opens under the keyboard
Reported 2026-08-19 from the device, with a screenshot. Long-pressing a bubble
while the keyboard is up showed the action menu behind the keyboard: only
«Ответить» peeked above it, the rest was unreachable.
Closed by 2114f62: the overlay sends the keyboard down as it opens
(`window.endEditing`), so the card lays out against the full screen; the draft
stays in the composer. Verified live on a simulator with the keyboard up:
all seven actions on screen, the draft intact after the menu closes
(`docs/qa/runs/2026-08-19-longpress-run.md`).

### The lifted bubble doubles its shape in the context menu
Reported 2026-08-19 from the device, with a screenshot. In the opened context
menu the bubble was drawn twice: behind the lifted copy a second outline stuck
out, offset up and left, with its own tail.
Closed by 2114f62: it was the original left visible under the overlay — the
scrim's gradient is transparent at the focus, and whenever the snapshot moved
away from the origin (with the keyboard up it always does) the source bubble
read through the blur as a second outline. The overlay now hides the source
bubble for its lifetime and returns the snapshot to the bubble's current frame
on dismissal, since the feed relayouts underneath when the keyboard leaves.

### The caret jumps in front of the first typed character
Reported 2026-08-19 from the device, screen recording
(`ScreenRecording_08-19-2026 20-16-45_1.MP4` in the owner's Downloads). Typing
"123" produced "231": the composer's programmatic write restored the caret by
its absolute position, and when the binding runs ahead of the view — the first
character of a field the view still reports as empty — that position is 0, so
everything after the first character typed in front of it.
Closed by the 2026-08-20 fix: the write keeps the caret's distance from the
end of the text instead. `ComposerCaretTests` fails on the old rule and passes
on the new one; MsngrTests green whole. Confirmed by the owner on 2026-08-21
(«баг уже поправили»), and a live simulator run the same day typed 20
characters in order with the caret at the end throughout.

### Typing in the chat input misbehaves under load
Reported 2026-08-19: when the app stutters, letters appear with a delay, the
input's resize lags, and sometimes the caret ends up behind the just-typed
text. The caret half was the absolute-position restore above; the same
2026-08-20 fix removed it, and the composer only writes into the field when
the binding holds a value the view never reported (send-clear, draft, edit),
so ordinary typing takes no programmatic write at all.
Closed with the owner's 2026-08-21 confirmation and a live run on main
(d166273): 20 fast HID keystrokes landed in order with the caret at the end,
and insertion after a word-replacement kept its place. The one full-field
wipe seen in the run was the system's autocorrect replacing a tapped
misspelled "word" wholesale — stock UITextView behaviour, not the composer.

### The UI tests cannot find the user search field on a localized host
Found 2026-08-21 while reproducing the lost tap below: `VoiceTests` and
`SmokeTests` reach the new chat sheet by `app.searchFields["Username or name"]`,
which matches the field by its placeholder. The simulators inherit the host's
ru-RU locale, so the placeholder reads «Введите юзернейм или имя собеседника»
and the lookup finds nothing — the fallback path that opens a chat with a peer
the device has no row for dies at "no user search field", and every voice test
run on a fresh user fails there before it reaches what it tests.
Closed by 58da84d: both suites now take the first search field that answers a
touch — the list's own field sits behind the sheet and is not hittable, which
is what tells the two apart, and no placeholder is named. Verified live: the
sheet's field is the only hittable one in the tree on a ru simulator
(`newchat` accessibility dump, 2026-08-21).

### The date capsule sits closer to the previous day than to its own
Reported by the owner 2026-08-28 with a screenshot: the «Сегодня»/«Вчера»
capsule hugs the last message of the previous day (~5 pt) while the first
message of the new day stands ~13 pt away — the message brings its own series
gap (`BubbleLayout.normalGap`) on that side and the capsule's padding is
symmetric, so the air is not.
Closed: `DateSeparatorCell` now shifts the capsule half the series gap toward
the older day, which makes both sides come out equal (~9 pt).
`DateSeparatorSpacingTests` holds the shift; verified live on the Bravo chat
with «Сегодня» between yesterday's and today's messages.

## 2026-08-28 — a bubble shader behind a long text crashed the app

Reported by the owner from the simulator log: `CAMetalLayer ignoring invalid
setDrawableSize width=915 height=37350`, then Metal's assertion
`MTLTextureDescriptor has height (37350) greater than the maximum allowed size
of 8192`. A text message thousands of lines long carried a `bubbleShader`; the
canvas took the bubble's full height, MTKView resized the drawable to match,
and the renderer asked for a feedback buffer of the same size. Fixed in the
same day: the canvas sizes its own drawable under a ceiling (8192 px, 2048 px
for the backdrop of a text bubble) keeping the aspect, and the renderer skips a
frame whose drawable is past the limit instead of allocating.

## 2026-08-28 — the shader surfaces run live

Found while running the remaining shader surfaces on the simulator (charlie
and alfa on two simulators, the owner had already seen the background and the
bubble shader work).

### A reaction of your own raised no burst
The reaction burst was checked only in the update path that inserts or
removes items; a reaction changes an item in place (`oldIds == newIds`), and
that path refreshed the cell without the effect. Closed: the check lives in
`burstIfReactionLanded` and both paths call it; seen live as confetti out of
the bubble.

### Your own shader avatar was a black disc in Settings
A canvas denied a budget slot draws one held frame — but only if it already has
a size, and the slot is asked for before layout; nothing drew the frame later.
Closed: `layoutSubviews` draws the held frame of a canvas that wants to run and
has no slot, and a canvas leaving the window gives its slot back. Seen live:
the avatar in Settings and on the peer's chat list.

### The context menu shows a shader message as a black rectangle
Reported by the owner on 2026-08-28 for the bubble shader too: a long-press
on a text over a shader lifted the bubble with the shader missing. The
overlay's snapshot is `layer.render`, which a Metal layer contributes nothing
to. Closed: the overlay now lays a live `ShaderCanvas` with the same document
over the lifted snapshot — the bubble shader under the selectable text, the
shader message and the sticker in their frames (`MessageContextOverlay.LiveShader`).

### The pond sticker's bottom read as a dot grid
Reported by the owner on 2026-08-28 («некрасиво сетчатый фон»): the bundled
Pond sticker drew its pebbles on a visible square lattice. Closed: the bottom
is mottled sand under a caustic web, both from value noise with no lattice
(`ShaderGallery.pond`).
