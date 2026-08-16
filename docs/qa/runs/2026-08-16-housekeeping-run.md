# The disk cleans up after agents that did not

Agents leave a simulator of about two gigabytes each, a stand, a worktree and a
derived-data directory, and the ones that are killed leave all of it booted and
running. Nine abandoned simulators had to be shut down by hand on the morning of
this run. This is the machinery that replaces that hand: a metric that answers
at once, a sweep on a five-minute clock, and a report for the human when the
sweep is not enough.

## Stand

The live machine, with other agents working throughout: `chatsearch` on
`chatsearch-agent` and `chatsearch-peer`, `perfdb` on `perfdb-a` and `perfdb-b`,
and `chatlist` on `chatlist-a` and `chatlist-b`, which started midway through.
Not a scenario stand — the point was to run the sweep against real agents whose
work must survive it. The shared `wrangler dev` on :8787 and `server/.wrangler`
were untouched.

## What was built

`scripts/disk.py` prints a stored snapshot and how old it is, because a walk
over the simulators and the derived data takes 3 seconds warm and 95 seconds
when it also measures the rest of the home directory, and nobody waits that long
for an answer. Free space is the one number read live, one syscall. `--scan`
takes a new snapshot; `--wide` also walks `$HOME`, which is what lets the report
say how much of a full disk is even ours.

`scripts/tidy.py` replaces `scripts/tidy.sh` and runs from launchd every five
minutes instead of every hour. It takes, without asking: a simulator whose agent
has finished, a stand no wrangler points at, wranglers still running for a
worktree that was deleted, a worktree whose branch is in main with nothing
uncommitted and nobody in it, derived data of a vanished workspace, logs older
than three days. Below a floor of free space it writes `.claude/disk-report.md`
and raises a notification instead of stopping quietly.

Ownership is by name: `perfdb` owns `perfdb-a` and `perfdb-b`. An agent is alive
while its process is in `ps` or its transcript is still being written.

## The run

| Step | Expectation | Fact |
|------|-------------|------|
| two simulators created, app installed and launched, left booted: `zombie-a` claimed by nobody, `ghost-b` behind a registry entry with a dead session | both read as litter, the six working simulators do not | dry run listed `zombie-a` and `ghost-b` and nothing else |
| sweep applied | both go, everything else stays | `removed simulator ghost-b (1.61G)`, `removed simulator zombie-a (1.65G)`; `chatsearch-agent`, `chatsearch-peer`, `perfdb-a`, `perfdb-b`, `chatlist-a`, `chatlist-b`, `gate-runner` and the owner's two devices all still listed |
| merged worktrees with nobody in them | removed with their stands | `run-english2`, `run-perfnet`, `run-search` gone; `run-chatsearch`, `run-perfdb`, `run-chatlist`, `run-housekeeping` kept |
| wranglers of five deleted worktrees, running 9 to 13 hours | killed, and the space they held returns | 36 processes gone; the 2.46 GB of deleted-but-open files held by `workerd` disappeared from `lsof +L1` |
| `perfdb` finished mid-run, its two simulators still booted | swept on the next pass | `removed simulator perfdb-a (2.00G)`, `perfdb-b (2.03G)`, 18 minutes after its transcript went quiet |
| free space forced below the floor (`TIDY_FLOOR_GB=100`) | a report naming what to give up next | `.claude/disk-report.md` written, notification raised, nothing deleted |

The whole sweep costs about two seconds, so running it every five minutes is
cheaper than the snapshot it refreshes.

## What the live machine corrected

Five rules that read correctly and were wrong on this machine. Each was caught
by running the thing, not by looking at it.

**The old idle check never ran.** `scripts/tidy.sh` aged simulators with `stat
-f %m`, which is BSD syntax; GNU coreutils are first in this `PATH`, so the
command failed, the age came out empty, and `[ "$age_h" -lt 2 ]` errored instead
of skipping. The guard that was supposed to spare a simulator idle for less than
two hours had been passing everything through.

**A booted simulator is never quiet.** The first idleness test watched
`data/Containers`. A booted simulator writes there forever on its own — Siri,
news, splash-screen snapshots, seventy-odd system group containers — so every
simulator looked busy. Only our own app group, `group.ai.enface.msngr`, is
written by our app and by nothing else: 8 minutes on an abandoned device, 0 on a
working one, 303 on one sitting idle.

**And a booted simulator is never quiet in the other direction either.** After
`perfdb` finished, its simulators kept writing `perf-trace.jsonl` every second
and the SQLite WAL every fifteen, hours after the agent was gone. Waiting for
quiet before deleting them would have waited forever. The registry decides for a
name it knows; quiet only decides for a name nothing claims at all.

**Every branch here is merged into main, including the ones being worked on.**
The rule "remove a worktree whose branch is merged" matched `run-chatsearch` and
`run-perfdb` while both agents were mid-run. Liveness has to be checked first,
and the tree has to be clean and empty of processes.

**Matching a command line matched the agent itself.** Killing wranglers of
deleted worktrees searched the whole `ps` line for `/worktrees/`. An agent is
started with its worktree path spelled out in its prompt, so the live `chatlist`
agent matched its own prompt text and was one `--apply` away from being killed
by the cleaner. Only the program and the script it was handed are looked at now,
never the arguments.

A sixth was caught the same way: `chatlist` had not written itself into
`.claude/agents.tsv` at all, so the registry alone would have called its two
simulators litter. A session writing into a worktree now claims it whether or
not anyone registered it.

## Do three agents fit in 85 GB

Yes, with room to spare — the measured answer is about 37 GB.

| | GB |
|---|---|
| the owner's two devices and the gate runner | 11.6 |
| shared build caches (`ModuleCache` and friends) | 2.3 |
| the main checkout with `.git` | 2.6 |
| the shared stand and the SwiftPM cache | 0.6 |
| **fixed, whatever is running** | **17.1** |
| per agent: two simulators | 4.0–4.3 |
| per agent: worktree with `node_modules` | 0.3–1.0 |
| per agent: its own derived data | 0.6–1.0 |
| per agent: its stand | 0.1–0.9 |
| **per agent** | **5.0–7.2** |
| **fixed plus three agents** | **32–39** |

The footprint measured during this run, with three agents working and the litter
of several dead ones still on disk, was 35.4 GB.

The 85 GB is `~/ws`, which measures 84.8 GB — but only 8.35 GB of that is msngr.
The rest is the other projects living beside it. Our own share of `~/Library`,
which is the simulators and the derived data, is 27.1 GB. Whatever the disk was
holding when this started cannot be reconstructed now, so this run does not
claim a before-and-after; what it measures is the steady state, and the steady
state has never been near 85 GB.

What does grow without bound is scratch: `scratchpad/` held 2.35 GB from runs
that ended days ago. The sweep does not take it, because a run report may still
be half-written in there; it is the first thing the escalation report offers.

## What the run did not cover

The escalation was exercised by moving the floor, not by filling the disk to 25
GB free. The path is the same either way — the sweep runs, free space is read,
the report is written — but the numbers in it came from a machine that was not
actually short of space.

Whether the five-minute job survives a reboot and a logout is not shown here.
`RunAtLoad` is false, so the first sweep after a login comes five minutes later.
