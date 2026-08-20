# Pinning at any depth: a live run on two simulators

Run date: 2026-08-20. Closes the two behaviours left after
`f3df882` (pinned bar drawn from its own row): the tap on the bar reaching a
pin far below the feed window, and a pin applying to both members before the
next chat-state sync. Measured against `docs/qa/runs/2026-08-16-large-chat-perf-run.md`,
which found neither working: the bar had nothing to jump to, and the local
`pinnedMsgId` stayed empty until a restart.

## Stand

Own `wrangler dev` on :8805, own `--persist-to` outside the repository,
`APNS_HOST` pointed at an unused mock. Two own simulators, iPhone 17, iOS 26.5:
`pin-a` (23B9A339) as user `9010`, `pin-b` (3F0F8BF4) as user `8009`. Built from
the working tree after merging main (`e87077a`): the fanout rework landed
there mid-run (outbox-per-recipient with unbounded retry), and both accounts
were registered fresh afterwards — the branch's own crypto-identity merge made
every earlier account's identity key unsigned and unusable for a new session.

## What was fixed

`ChatViewModel.observePinnedMessage` (commit `f3df882`) reads the pinned row by
its own `ValueObservation` keyed on `msgId`, not by scanning the loaded window;
the bar's tap goes through `jump(to:)`, which calls `ensureLoaded` and pages
history in before scrolling. `SyncEngine.pinMessage` (this run) writes
`chat.pinnedMsgId` locally at once and queues the server call through
`pendingAction`, the same path `markRead`/`deleteMessages` use; `upsertChatState`
skips overwriting the local pin while that action is still pending, so a
snapshot that raced the request cannot put the previous pin back.

## The scenario

Direct chat between `9010` and `8009`, seeded to 3000 messages each way through
the DEBUG send buttons (the regular send path, real encryption and outbox).
Message 31 of the first thousand-message batch — seq 2031 against `lastSeq`
3000, 969 messages behind the newest — was pinned from a long-press on `9010`'s
device while the feed stood at the end of the chat (window: newest 60).

`chat.pinnedMsgId` on both devices changed inside the same one-second poll
window; the local write is synchronous with the tap, so the bar appeared on
the pinning device before the fanout job round-tripped through the server, and
on the peer device the moment its socket delivered the `chat`/`pinned` frame
(the outbox-per-recipient rework merged this run means that frame is retried
until acknowledged rather than sitting on a shared queue behind an unrelated
head-of-line message).

Tapping the bar on **both** devices independently — `9010` first, `8009`
afterward, each with the feed sitting at the bottom on the newest 60 messages —
scrolled straight to "Test message 31 of 1000" with no failed jump. On `9010`,
`PerfTrace` marks put `jump.begin` → `jump.loaded` at 55 ms, all subsequent
frames at 16.7 ms (60 fps, nothing over budget) — the window grew from 60 to
past the target in one pass, no stall visible to the reader.

## A defect found along the way, out of this scope

`NewChatView`'s "Новый чат" search-result row does not open a chat: tapping a
result (confirmed against the accessibility tree's own button frame, not a
guessed coordinate) does nothing — no `POST /api/chats` reaches the server, no
local chat row appears, and the screen sits unchanged. Reproduced on both
simulators, independently, against fresh accounts with signed identity keys
(ruling out the already-open "unsigned bundle" defect). The two-client scenario
above worked around it by creating the chat directly through
`POST /api/chats` (the same call `DirectChat.open` makes) and letting each
app's own snapshot/WS pick it up — proving the pin behaviour itself, not the
chat-creation tap. Logged in `docs/qa/defects.md`.

## Gate

`make check DEV_UDID=14C70E21-A23A-4492-8E6A-113AE0BC6B6D` (gate-runner): green
— `xcodegen`, build, `swift test`, MsngrTests, server smoke against the
gate's own throwaway stand, no fresh crashes. `make uicheck
DEV_UDID=23B9A339-41FE-4BDA-90ED-C1A76361BE8E` against the shared stand:
green.

## What was not measured

Statement-level SQL/VM-step counts for this exact scenario, the way the
2026-08-16 run measured the jump before the fix. `PerfTrace` marks confirm the
jump cost is in the same 16.7 ms/frame band the earlier run's search-jump
scenario landed in at a similar depth (900-row window), not a fresh count.
