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

### Unread count inflated in group chats
Reported 2026-08-19. The unread badge of a group counts more than the chat
list shows. Code reading points at `ConversationDO`: the counting mark
(`seenMarks`) absorbs a service frame only when the chat is already read
(`seen >= seq - 1`). With unread content in the chat, a reaction, an edit or a
group event still bumps `lastSeq`, so the server-side unread — and the badge
built from it — grows by a frame the client never shows. Groups feel it most:
membership events are frequent. Assigned to the receipts run: red smoke check
first, then the fix.

Reproduced 2026-08-19 by a check in the server smoke, before any change to the
product: in a group with one unread message, a service frame and then a second
message, the badge on the push arrived as 3 where the reader had two messages to
open (`a service frame does not grow an unread badge`, commit d09b138). The same
count on the device was inflated the same way, by the same rule, and is covered
by `UnreadCountTests`.

Fixed by counting unread in content rather than in seqs: `ConversationDO` keeps
a running count of content messages and stores it on every message, so unread is
the distance between the count at a member's mark and the chat's current one
(8eb1899); the chat row on the device counts a message when a frame takes the
chat further than it has ever been, and a service frame adds nothing (d36f0cc).

### Bubble resize on a reaction change is not animated
Reported 2026-08-18. Adding or removing a reaction snaps the bubble to its new
size. Cause found: `MessagesViewController.refreshItem` falls back to
`UIView.performWithoutAnimation { reloadItems }` when the height changes.
Assigned to the bubbleanim run.

### Long-press on a bubble has no animation
Reported 2026-08-18. The context menu appears without the Telegram-style
press-and-lift animation of the bubble itself. Assigned to the bubbleanim run.

### Interaction smoothness below Telegram
Reported 2026-08-18. Overall animation quality and frame pacing feel worse
than Telegram across the app. Umbrella item for the bubbleanim run; closes on
the owner's judgement, not on a single fix.

## Closed

### Read tick colour invisible, single tick oversized
Reported 2026-08-18. Closed by 95c03a3: the read tick got its own hue per
theme, the single tick the same glyph size as one of the pair.

### Back button in the chat header oversized
Reported 2026-08-18 (third time). Closed by 95c03a3: the custom button now
draws the system chevron at the system size, kept only for the `chat.back`
accessibility identifier; the header title sits on a capsule ground.
