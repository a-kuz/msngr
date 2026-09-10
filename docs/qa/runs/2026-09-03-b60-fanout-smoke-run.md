# B60: the gate's red on e254d08 at «stalled recipient catches up after retries» — 2026-09-03

The server smoke in a loop against throwaway stands on this host, main at
91549fd (the RPC pass merged, no server change since e254d08), wrangler 4.86
from `server/node_modules`, each run on a fresh `--persist-to` directory with
its own port pair. Two loops: six runs on an otherwise idle host, then runs
with seven `yes` processes pinned to cores while other agents' builds took the
load average to 820–860. No server code changed in this line; what changed is
the smoke and the two scripts around it.

## What the gate saw

`.claude/gates/609cfb28b08b.log`: section 23 of the smoke, `FAIL stalled
recipient catches up after retries`, then `GET /api/chats/:id/fanout` unanswered
until undici's 300 s headers timeout killed the run. The stand's own log went
with its temporary directory, so nothing of the server's side survived.

## The red, reproduced and explained

The stand logs of the loop show the order of events around the fault hook.
Section 22 ends with `fault(99)` (Mallory's object rejects every delivery),
two messages queued for her, then `fault(0)`. Section 23 armed `fault(2)` at
once and sent a burst of six, expecting the burst's head to fail twice.

Run 1, idle host (stand log, ANSI stripped):

```
POST /api/dev/fault            fault(0)
POST /api/dev/fault            fault(2)
GET  /api/chats/…/fanout
fanout: msg to <mallory> … failed (attempt 3)
fanout: msg to <mallory> … failed (attempt 4)
```

The two faults were spent on the retries of `cm-f2`, still on its backoff from
section 22, not on the burst. `cm-f2` then waited its next pause (5 s), and the
burst went out behind it: about 8 s after `fault(2)` on an idle host, inside
the 20 s the check allows. On the gate's loaded host the acks and the fault
posts land later against the same retry schedule, one pause further along the
`FANOUT_RETRY_MS` ladder (200 ms, 1 s, 2 s, 5 s, 10 s), and the burst arrives
after the 20 s. The same race was in the smoke before the RPC pass; 9c48a0b
passed it by timing.

Under load the race showed a second face (run 5, seven cores busy): the drain
wait I had added made the faults hit the burst's head as intended (`attempt 1`,
`attempt 2` in the stand log after `fault(2)`), but the six acks took longer
than the 1.2 s of those two retries, and `fanout is queued, not inline` read
`pending: 0` — the queue had already gone through. Every delivery check after
it passed in that run.

The product delivered every message in every run: 6 idle runs and the loaded
runs below, 486–488 of the checks green, the only reds these two timing
readings of the test itself.

## The hang, not reproduced

No request hung in any run here; `/fanout` answered in 1–392 ms (the 392 ms
under load). msngr-5e, whose private smoke ran at the same minute as the gate's
(both stands started around 02:59), points out that `smoke-stand.sh` picked its
push port with `lsof` before the smoke had bound the receiver, so two scripts
starting together got the same port: the gate's stand and theirs pushed into
one receiver. I reproduced that collision between my own two loops (both on
:9890). Whether the shared receiver is what froze the gate's request is not
shown; the hang stays unconfirmed, and the next occurrence will carry its
evidence: the smoke now ends with the path of a request unanswered for 30 s,
and `smoke-stand.sh` prints the stand's warnings and errors into the gate log
on a red run.

## What changed

- `server/test/smoke.mjs`: section 23 waits for Mallory's backlog to drain
  before arming the fault (`recovered recipient's backlog drained`, one more
  check); the burst's head is stuck by `fault(99)` until the queue has been
  read, then `fault(0)` lifts it, so the reading no longer depends on a time
  window; `apiRaw` aborts a request after 30 s with the path in the error.
- `scripts/smoke-stand.sh`: a port is taken by `mkdir /tmp/msngr-smoke-ports/<port>`
  (atomic, released on exit) instead of an `lsof` look; on a non-zero exit the
  stand log's `WARNING`/`ERROR`/`fanout:` lines are printed.
- `scripts/tidy.py`: a worktree whose agent has a line in `.claude/tasks.tsv`
  is not removed. Under the new cycle the claim lands on main before any work,
  so a fresh worktree is «branch merged, nothing uncommitted» from its first
  minute; mine was swept three minutes in (`.claude/tidy.log`, 04:18:07).

## Runs

Idle host, worktree smoke as it stood at the time (runs 1–3 the original
section 23, runs 4–6 with the drain wait):

| run | s | ok | FAIL |
|---|---|---|---|
| 1 | 101 | 487 | 0 |
| 2 | 107 | 487 | 0 |
| 3 | 106 | 487 | 0 |
| 4 | 99 | 488 | 0 |
| 5 | 100 | 486 | 2 — `fanout is queued, not inline`, `a queued job reports its wait` (pending 0, the second face above; my loaded loop had started beside it) |
| 6 | 120 | 488 | 0 |

Seven cores busy plus the host's own load (load average 820–860):

| run | smoke version | s | ok | FAIL |
|---|---|---|---|---|
| 1 | drain wait, `fault(2)` | 102 | 488 | 0 |
| 2 | drain wait, `fault(2)` | 104 | 488 | 0 |
| 3 | drain wait, `fault(99)` then `fault(0)` (the delivered version) | 109 | 488 | 0 |
| 4 | the delivered version | 101 | 488 | 0 |

Run 3's stand log has the delivered order: three `/fanout` reads until the
backlog is gone, `fault(99)`, `attempt 1` and `attempt 2` failing on the
burst's head, the `/fanout` read with the queue standing, `fault(0)`, the
catch-up. `/fanout` answered in 2–209 ms throughout.

## Not done

- The hang itself: not reproduced, cause not shown (see above).
- `smoke.mjs` is 2859 lines, 491 checks in 54 order-coupled sections over one
  set of users; this red came from that coupling. Splitting it is a backlog
  line (B64), not this one.
- The lock directories under `/tmp/msngr-smoke-ports` are released by the
  script's exit trap; a script killed with SIGKILL leaves one behind and costs
  the range one port.
