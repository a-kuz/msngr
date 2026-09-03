# How msngr is built

The bar is Telegram or Signal. There is no production, there are no users,
and the owner's time is the scarce resource: everything below is arranged so
that the work runs without the owner in the loop, and the owner reads one
status line and takes product decisions.

Backward compatibility is not maintained: the database can be wiped and the
user re-registered, frames and REST change freely, keys and sessions may be
dropped. Versioning is wired in ahead of time (protocol version in the
handshake, schema version, `migrations` in `wrangler.jsonc`, a version on the
E2EE envelope) so there is a place to write the compatibility once there are
users to break. The shared stand follows the same rule (the owner's call,
2026-09-03): a change to what an object stores wipes the stand's state and
reseeds the trio; nothing is written to carry old state forward.

## Three files

- `ROADMAP.md` — what the product is and what state each feature is in
  (✅ confirmed by a live run, 🟡 built but not watched, ⬜ planned). Updated
  in the same commit as the code; a ✅ comes with a link to the evidence.
- `docs/BACKLOG.md` — the one queue of open work: defects, architecture
  lines, features, owner decisions. A session takes the topmost free line,
  writes its name in `who`, closes it with the commit and the evidence. There
  is no other list of open work anywhere in the repository.
- `.claude/gates/status.tsv` — one line per gated commit on main: sha, time,
  green or red, the log. Written by the gate job, read by the owner and by
  `scripts/progress.py`.

Everything else is evidence or reasoning: `docs/qa/runs/` (run reports with
numbers and screenshots), `docs/audits/` (why a backlog line exists),
`docs/qa/test-cases.md`, `docs/protocol.md`, `docs/crypto-flows.md`,
`docs/ui-spec.md`. A closed defect's story lives in its run report and in
git; nothing is copied into a second place.

## A session's cycle

1. Start in a worktree of your own: `EnterWorktree` (or `git worktree add
   .claude/worktrees/<name> -b <name>`). Nobody edits `main`'s checkout
   directly, and nobody shares a checkout: two sessions in one tree cost a
   hollow commit and half an hour of a broken stand on 2026-09-03.
2. Take the topmost free line of `docs/BACKLOG.md`: put your name in `who`
   and land that one-cell change on `main` at once (commit in the worktree,
   then `git push . HEAD:main`), before any other work — the claim is what
   keeps two sessions off one line; if `main` moved and the cell is taken,
   take the next. Add your line to `.claude/tasks.tsv` (name, start, one
   sentence) so `scripts/progress.py` shows what is in work; the file is
   untracked and lives only in the root checkout, so append to it by its
   absolute path from the shell (`printf '…\n' >>`). Your own
   simulator, your own stand on its own port; the shared stand is neither
   restarted nor wiped.
3. One behaviour per change, commits incremental. Delivery is closed by the
   check of the layer you touched — `swift test` for MsngrKit, `node
   test/smoke.mjs` for the server, MsngrTests for the app — plus a live run of
   the scenario on your simulator, watched, not just built. A red check on a
   product number is a defect until proven otherwise and is never answered
   from the test's side.
4. Merge into `main` yourself: `git merge main` in your worktree (resolve
   conflicts there), then `git push . HEAD:main`. A server change is then rsynced to the shared
   stand (`server/` on adad; `wrangler dev` there reloads on its own), a
   migration applied there by hand. Close the backlog line and the tasks.tsv
   line, update ROADMAP if a feature moved.
5. Report: what was done, what was verified and with which command or run,
   what was not done and why. A defect found in passing becomes a backlog
   line in the same commit.
6. Remove the worktree and your simulator.

`main` is moved from inside the worktree, never from `main`'s checkout.
`git push . HEAD:main` fast-forwards the branch and updates the shared
checkout's files with it (the repository's `receive.denyCurrentBranch` is
`updateInstead`, set once with `git config receive.denyCurrentBranch
updateInstead` if a fresh clone ever needs it). A push that is not a
fast-forward is refused: merge `main` into your branch and push again. A push
into a shared checkout with uncommitted changes is refused too, and that is
somebody editing `main` directly, not a reason to force anything.

A worktree-isolated session's harness refuses any command it cannot prove
stays off git in the shared checkout: `git -C <the main checkout>` is refused
outright, and so is a chain like `UDID=$(xcrun simctl create …) && xcrun
simctl boot $UDID`, because the value passed on is computed at runtime.
Write plain commands, one per call, with the literal id pasted in from the
previous output; a shell variable or a `$(…)` feeding another command is
what trips it, and so do a `for` loop and a `python3 - <<'EOF'` heredoc.
Anything bigger than one plain command is a file: write the script into
your scratchpad and run it by path (`python3 <scratchpad>/probe.py`), which
the harness passes.

Product decisions (section 5 of the backlog) are not taken by a session; the
line waits for the owner.

## The gate, without anybody waiting for it

`scripts/gate-watch.py` runs from launchd every two minutes
(`scripts/launchd/com.msngr.msngr.gate.plist`). When `main` has a commit it has
not gated, it checks that commit out into `.claude/gate-wt`, runs `make check`
there on the gate-runner simulator (xcodegen → build → `swift test` →
MsngrTests → the server smoke on a throwaway stand → fresh crash logs), and
appends one line to `.claude/gates/status.tsv`; the full log is
`.claude/gates/<sha>.log`. A red line is a defect report against that commit:
whoever sees it first opens a backlog line, and the fix goes forward on main.
Nobody waits for the gate before merging (the owner's call, 2026-08-19: its
reds had been the host, not the code, every time), and nobody runs it by hand
in a shared checkout — a build over files somebody is editing measures
nothing.

The UI smoke (`make uicheck`) is outside the process: run it only when asked,
on your own simulator (the owner's call, 2026-08-31).

## The state matrix

A feature is run along a row of the matrix rather than down the happy path:

| Axis | Values |
|------|--------|
| Network | online / offline / dropped mid-operation / reconnect |
| Content | short / long (200 lines) / emoji / RTL / links |
| Devices | one / two (sender and receiver) |
| Lifecycle | active / background→foreground / killed mid-operation |
| Chat state | new (message request) / accepted / group |

## Audits, QA, runs

The audit → test cases → run → fix cycle is run by sessions off the backlog
like any other line, not by the owner: an audit's findings become backlog
lines in the audit's own commit, a run report closes the lines it verified,
a crash (`scripts/collect-crashes.sh`) is a backlog line until it is
understood.

## Stands and simulators

The shared stand and the simulators are described in `CLAUDE.md` («The
stand», «Simulators»). In short: the shared stand is on adad behind
`msngr.a-kuz.online` and is never restarted or wiped without being asked; the
owner's two simulators are not touched; `14C70E21-…` (gate-runner) belongs to
the gate job; every session creates and deletes its own.
