# How msngr is built

The bar is Telegram or Signal. There is no production and no hurry, so nothing
ships without going through the pipeline below.

Backward compatibility is not maintained while the only users are the owner and
the development work itself. Losing every conversation is acceptable, and so is
breaking older builds: the database can be wiped and the user re-registered,
frames and REST change freely, keys and sessions may be dropped. No compat
layers, no recovery code.

Versioning is still wired in ahead of time, because it costs almost nothing: a
protocol version in the handshake (the client states its own, the server knows
the lowest it supports and answers with a legible "update the app" instead of a
silent disconnect), a database schema version (today a mismatch means wipe and
re-register, but the hook for a real migration stays), numbered D1 migrations
under `server/migrations/`, and a version on the E2EE envelope format. The
"support the old thing" branches are empty. What matters is having the place to
write them once there are users to break.

## Source of truth for the product

`ROADMAP.md` at the root is the only one: a tree of product features with
statuses (✅ done and confirmed by a live run, 🟡 partial or unverified live,
⬜ planned). Whoever closes a feature updates its status in the same commit, and
"done" needs evidence — a run under `docs/qa/runs` or a screenshot. The task
list inside a session is a working board for the current wave; it does not
outlive the session and is not a product plan. The technical backlog of defects
lives in `docs/audits`.

## Roles

The main context orchestrates: it assembles task packages, runs worktree agents
in parallel, merges their branches, resolves conflicts, runs the gate, and keeps
the backlog and the reports. The agents do the work — code, fixes, runs. Every
agent prompt carries its file boundaries, the requirement to build and test, and
the shape of the report: done, verified, not done. The shared stand (`wrangler
dev` on :8787, two simulators) is not restarted and its state is not wiped.

A simulator belongs to exactly one agent or to the owner at any moment. Agents
running UI scenarios in parallel create their own (`xcrun simctl create <name>
"iPhone 17"` → boot → install → register a fresh user) and delete them
afterwards (`shutdown` + `delete`). The owner's pair (dev 44CE2242, Pro Max
0E0CF155) goes to an agent only on an exclusive reservation, when the owner is
not testing on it. Slow Animations in Simulator.app is a global switch: turn it
off when you are done.

## The quality pipeline

### The `make check` gate, before every commit

1. `xcodegen` and an iOS app build.
2. Core unit tests (`swift test` in MsngrKit) — crypto, sync, outbox, storage
   migration, BlurHash, mosaic.
3. App unit tests (MsngrTests) — BubbleLayout, feed and grouping, the unread
   marker, notification decisions, registration validation.
4. UI smoke (MsngrUITests) — launch, registration, sending text, drafts, the
   long-press menu, the attach menu.
5. Server smoke (`node server/test/smoke.mjs`) — checks over the API, the DOs
   and pushes. The dev APNs mock has to be stopped for the duration: the
   smoke takes the same port, :9871. A stand of your own on another port runs
   as `wrangler dev --port <port> --var APNS_HOST:http://localhost:<sink port>`
   plus `BASE_URL=… PUSH_PORT=<sink port> node test/smoke.mjs`; `--var`
   overrides `.dev.vars` and the owner's mock is left alone.
6. Simulator crash logs (DiagnosticReports) — a fresh crash fails the gate.

The Makefile builds on the owner's simulator by default, so an agent runs the
gate on its own: `make check DEV_UDID=74B78AFC-E8D7-4317-B16F-E51A65504B2D`
(gate-runner).

### One change at a time

- Micro-scope: one behaviour per change.
- Then a live run of the affected scenario on a simulator, watched, not just
  built.
- Then a full `make check`.
- A regression found after delivery gets a reproducing test before the fix.

### The state matrix

Every feature is run along a row of the matrix rather than down the happy path:

| Axis | Values |
|------|--------|
| Network | online / offline / dropped mid-operation / reconnect |
| Content | short / long (200 lines) / emoji / RTL / links |
| Devices | one / two (sender and receiver) |
| Lifecycle | active / background→foreground / killed mid-operation |
| Chat state | new (message request) / accepted / group |

### The agent cycle, once per iteration, in batches

1. An auditor agent reads the code and writes the potential bugs into
   `docs/audits/`.
2. A QA agent writes test cases into `docs/qa/test-cases.md`.
3. A runner agent executes them on two simulators (a coordinate grid over a
   screenshot gives it precise taps) and reports into `docs/qa/runs/`.
4. The reports are worked through: every confirmed bug gets a reproducing test,
   then a fix, then a line in the regression suite.

### Crash triage

- After every run, by hand or by agent, `scripts/collect-crashes.sh` picks up
  fresh `.ips` files for the Msngr process from `~/Library/Logs/DiagnosticReports`,
  puts them in `docs/qa/crashes/` and symbolicates them.
- A crash is not closed until it is understood.

## Backlog

- `docs/audits/2026-08-12-code-audit.md` — 37 items, each open, confirmed, fixed
  or rejected.
- Order of work: crashes and data loss, then offline reliability, then E2EE edge
  cases, then UI.

## Stands

- Simulators: iPhone 17 dev `44CE2242-...` (bobby11), iPhone 17 Pro Max
  `0E0CF155-...` (445566).
- Server: `wrangler dev` on :8787. "Offline" means killing it.
- External runner: `~/ws/tetser-3` (ios-ai-tester), still being evaluated.
