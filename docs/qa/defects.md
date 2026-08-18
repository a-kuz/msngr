# Defect log

Defects reported by the owner, one entry each. An entry stays until the fix is
merged and the owner's scenario was re-run; then it moves to the closed list
with the commit that closed it.

## Open

### Unread count inflated in group chats
Reported 2026-08-19. The unread badge of a group counts more than the chat
list shows. Code reading points at `ConversationDO`: the counting mark
(`seenMarks`) absorbs a service frame only when the chat is already read
(`seen >= seq - 1`). With unread content in the chat, a reaction, an edit or a
group event still bumps `lastSeq`, so the server-side unread — and the badge
built from it — grows by a frame the client never shows. Groups feel it most:
membership events are frequent. Unverified live; needs a reproducing check in
the server smoke first.

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
