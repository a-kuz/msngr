# Where the work stands

Written 2026-08-19. This file exists because agent work lives on branches that
outlive the conversation that started them; without it a branch with a day of
work in it looks like clutter.

Delete an entry when its branch is merged and gone.

No agent is running: the owner asked for none to be started until they say so, so
both branches below are parked with their work committed and nothing in flight.

## Branches with work in them

**run-pin** — four commits of its own plus two merges of main. The pinned bar
reads its own message row through an observation instead of the feed window, a pin
is applied locally at once and told to the server through the action queue, and a
chat state frame that fails to apply now says so. The last commit is a probe:
whether a pin fans out to both members' sockets. What its live run turned up and
has not answered: a pin frame that spent 235 s in the fanout queue while the
second device stayed on its previous seq. Never verified live, no report yet.

**run-ticks** — one commit: `BurstTicksTests` between two live clients and
`server/test/tick-burst.mjs` on the server alone, both measuring the owner's
scenario of a hundred messages by the ticks each message earns rather than by the
burst as a whole. Written against `docs/qa/defects.md` «A burst arrives at one
message per second»; neither has been run to a verdict.

## In main since this morning

`run-crypto-identity` (identity binding, replay rule, sender key messages signed
whole) and `run-identityui` (username quarantine on migration 0005, the folders
screen in Russian with its own Edit/Done). Both merged with a green gate.

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
