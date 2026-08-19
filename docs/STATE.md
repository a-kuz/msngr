# Where the work stands

Written 2026-08-19. This file exists because agent work lives on branches that
outlive the conversation that started them; without it a branch with a day of
work in it looks like clutter.

Delete an entry when its branch is merged and gone.

One slot is open by the owner's word and taken: `longpress` works on
**run-longpress** — the context menu under the keyboard and the doubled bubble
outline, one interaction from the owner's device (task in its worktree).

## Branches with work in them

**run-pin** — four commits of its own plus two merges of main. The pinned bar
reads its own message row through an observation instead of the feed window, a pin
is applied locally at once and told to the server through the action queue, and a
chat state frame that fails to apply now says so. The last commit is a probe:
whether a pin fans out to both members' sockets. What its live run turned up —
a pin frame that spent 235 s in the fanout queue — is answered by run-delivery's
merge: the fanout is now a per-recipient outbox with unlimited retries. The pin
behaviour itself is never verified live, no report yet; its agent waits on the
session limit and resumes with «продолжай».

## In main since this morning

`run-delivery` — the fanout as an outbox (a delivery record per recipient that
lives until acknowledged, independent chains, retries with no attempt cap), the
push moved out of the delivery path into its own persisted queue, and the live
run in `docs/qa/runs/2026-08-19-delivery-run.md`: a 100-burst lands in 255 ms,
ticks follow within ~100 ms, and chats keep working with APNs fully down.
run-ticks' measuring pair (`BurstTicksTests`, `server/test/tick-burst.mjs`) came
along; both branches are deleted.

Also `run-crypto-identity` (identity binding, replay rule, sender key messages
signed whole) and `run-identityui` (username quarantine on migration 0005, the
folders screen in Russian with its own Edit/Done). All merged with a green gate.

The gate itself changed: `scripts/collect-crashes.sh` now fails on our own
crashes and only reports a launch failure of the XCTest harness, which had been
failing the gate off a stale runner bundle on a simulator that was not ours.

Two defects the owner reported were closed in `b73cc80`: a send nobody could read
now fails and stays in the outbox instead of showing a tick, and a deleted direct
chat can be opened again without waiting for the peer to write.

`docs/research/2026-08-19-per-user-do.md` holds the target backend: a DO per user
and per handle, subscriptions between objects instead of asking, and outbox to
inbox as the delivery guarantee.

## Not started, specified

- Reaction animations — waiting for a model that can debug animation frame by
  frame; the owner asked not to hand this to a general-purpose agent.
- `docs/protocol.md` and `docs/crypto-flows.md` are still in Russian and get their
  own pass.
- Splitting into three private repositories, and rewriting the commit history in
  English. The history also carries deleted screenshots and build artefacts, so
  `.git` is around 460 MB against 368 KB of docs.

## How agents are run

`.claude/ORCHESTRATION.md` holds it: two slots, a session per agent resumed with
`claude --resume`, and course corrections sent with `SendMessage` instead of a kill.
