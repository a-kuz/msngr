# Defect log

Defects reported by the owner, one entry each. An entry stays until the fix is
merged and the owner's scenario was re-run; then it moves to the closed list
with the commit that closed it.

## Open

### Unread counts must work offline, and the read must reach the server later
Reported 2026-08-19. On a plane: the chat list shows 5 unread, opening the
chat drops it to 0 — all with no network — and the moment the network is back
the read mark goes to the server. The code is built for this (`markRead`
writes `myReadUpTo` and zeroes `unreadCount` locally in one transaction and
queues the server send as a `pendingAction` drained on reconnect), but the
scenario was never run live. Needs an offline run on two simulators: unread
accumulates, the stand goes down, the reader opens the chat, the stand comes
back — the sender must end at «прочитано», with no unread resurrection on the
reader after sync. Queued for the next free slot.

### Interaction smoothness below Telegram
Reported 2026-08-18. Overall animation quality and frame pacing feel worse
than Telegram across the app. Umbrella item; closes on the owner's judgement,
not on a single fix. Measured so far (bubbleanim run, merged 14c3a0a): no
frame over 36 ms in the reaction windows, `feed.ui.apply` ≤ 3 ms.

## Closed

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
