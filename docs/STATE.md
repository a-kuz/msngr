# Where the work stands

Written 2026-08-19. This file exists because agent work lives on branches that
outlive the conversation that started them; without it a branch with a day of
work in it looks like clutter.

Delete an entry when its branch is merged and gone.

One slot is open by the owner's word and taken: `media` on **run-media** — media
has to appear in the feed the instant it is sent, blurred in its frame first and
the preview once it is ready. `.claude/agents.tsv` holds only live work, so
`scripts/agents.py` is the picture of the site.

## Merged on 2026-08-20

run-pin (`1a3f008`, the pinned bar reaches a message a thousand behind the newest
and a pin applies to both members within a second — numbers in
`docs/qa/runs/2026-08-20-pin-depth-run.md`), run-longpress (`48dadad`, the
context menu clears the keyboard and one bubble is
lifted), and a run of the owner's device defects straight on main: the composer
caret that put «123» in as «231» (`33f30f8`), the empty-screen glyph that turned
to mud in the dark appearance (`5f95956`), list rows that answered only on their
letters (`324c4d2`), the chat search that fired a request per keystroke
(`3cdfbb9`), and the chat list's navigation bar coming back from a chat washed
out — its cause was the custom back button. Sends to accounts registered before
the identity binding no longer hang the whole outbox (`123a23d`), and the in-app
banner is laid out inside its own window band with tests holding that shape.
Every fix has its story in `docs/qa/defects.md`; the gate ran green after each.

## In main since 2026-08-19

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
