# Where the work stands

Written 2026-08-19. This file exists because agent work lives on branches that
outlive the conversation that started them; without it a branch with a day of
work in it looks like clutter.

Delete an entry when its branch is merged and gone.

## Branches with work in them

**run-pin** — one commit. The pinned bar reads its own message row through an
observation instead of the feed window, so a pin deeper than the window still
draws. Two behaviours are still open: the tap has to load history before it jumps,
and a pin does not apply until the next chat-state sync. Both measured in
`docs/qa/runs/2026-08-16-large-chat-perf-run.md`. Never watched live. Its agent
`pin` is waiting out the token limit and continues in its own session.

**run-identityui** — one commit. A username freed by a rename stays out of
circulation for two weeks for everyone but its previous owner
(`server/migrations/0004_username_quarantine.sql`, renumbered to 0005 after the
crypto merge took 0004), and the @handle in people search has a text role of its
own. The migration has never been applied and the rewritten smoke has never run.
Its agent `identityui` is working on it, on a stand of its own on :8803.

## Merged and free to delete

`run-crypto-identity` is in main as of `eed62e8`: the identity binding, the replay
rule, sender key messages signed whole, skipped message keys evicted by age, and
`docs/audits/2026-08-16-crypto.md`. Merging it changes registration, so users on
the shared stand register again.

These branches carry nothing main does not already have: `run-chatlist`,
`run-chatsearch`, `run-english2`, `run-housekeeping`, `run-perfdb`, `run-perfnet`,
`run-search`, `run-statusbar`, `run-crypto-identity`.

## Not started, specified

- Reaction animations — waiting for a model that can debug animation frame by
  frame; the owner asked not to hand this to a general-purpose agent.
- `docs/protocol.md` and `docs/crypto-flows.md` are still in Russian and get their
  own pass.
- Splitting into three private repositories, and rewriting the commit history in
  English. The history also carries deleted screenshots and build artefacts, so
  `.git` is around 460 MB against 368 KB of docs.

## How agents are run

`.claude/ORCHESTRATION.md` holds it: two slots, a session per agent continued with
`claude -r`, the token limit waited out rather than replaced with a fresh session,
and course corrections sent with `SendMessage` instead of a kill.
