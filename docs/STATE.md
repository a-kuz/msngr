# Where the work stands

Written 2026-08-16. This file exists because agent work lives on branches that
outlive the conversation that started them; without it a branch with a day of
work in it looks like clutter.

Delete an entry when its branch is merged and gone.

## Branches waiting to be merged

**run-english** — 24 commits, finished. `PROCESS.md` and `ui-spec.md` translated,
the five Russian run reports translated, Russian comments swept out of the
sources. While translating the UI spec it also corrected what that document said
about the feed window and the badge, which had gone stale. Ready to merge.

**run-media** — 2 commits, finished. Media close-out: video playback, blurhash,
album mosaic, photo caption. Report in `docs/qa/runs/2026-08-16-media-close-out-run.md`.
Ready to merge.

**run-audit** — running. Triaging `docs/audits/2026-08-12-code-audit.md`, fixing
what survives triage. 11 commits so far.

**run-device** — running. Signing in on a second device: design in
`docs/research/2026-08-16-second-device.md`, then server and client. 6 commits so
far, and the live run has both devices exchanging messages after linking.

**worktree-agent-ab653cb1fa7bfbfa5** — 12 commits, agent died (session limit).
Chat screen defects from `docs/audits/2026-08-16-chat-ui.md`: delete through
selection, status-bar tap, send-scrolls-to-end, reaction insets, in-place text
selection, back-swipe. Never verified live. Its worktree is gone; the branch is
not. Pick it up with a fresh agent reading the diff.

**worktree-agent-ad5c9c3de9254ee23** — 5 commits, superseded by the branch above,
which merged it. Keep until that one lands, then delete both together.

## Not started, specified

- Reaction animations — waiting for a model that can debug animation frame by
  frame; the owner asked not to hand this to a general-purpose agent.
- Search inside one chat — `docs/audits/2026-08-16-chat-ui.md` item 4. The query
  layer for it already exists (`MessageSearch.page(chatId:)`), only the screen is
  missing.
- `docs/protocol.md` and `docs/crypto-flows.md` are still in Russian; they were
  left out of the English sweep because the second-device agent is rewriting
  them. They get their own pass afterwards.
- Splitting into three private repositories, and rewriting the commit history in
  English. The history also carries the deleted screenshots and build artefacts,
  so `.git` is around 460 MB against 368 KB of docs.

## How agents are run

As their own processes, not through the Agent tool:

    cd .claude/worktrees/<name>
    nohup claude -p --session-id <uuid> --permission-mode bypassPermissions \
      "$(cat task.md)" < /dev/null >> run.log 2>&1 &

The session id is ours, so `claude -r <uuid> -p "..."` resumes after any
interruption, and no stall watchdog applies. To steer one mid-flight: `kill` the
pid, then resume with new instructions — nothing on disk is lost.

`scripts/agents.sh` reads `.claude/agents.tsv` (name, session id, worktree) and
says which are alive, stuck or done. `scripts/tidy.sh` reclaims what dead agents
leave behind; launchd runs it hourly.
