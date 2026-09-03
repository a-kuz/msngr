#!/usr/bin/env python3
"""The gate that nobody waits for.

Run from launchd every two minutes. When `main` has a commit that has not been
gated yet, the commit is checked out into its own worktree (`.claude/gate-wt`,
so nobody's live edits are measured), `make check` runs there on the
gate-runner simulator, and one line goes to `.claude/gates/status.tsv`:

    <sha>\t<started>\t<green|red>\t<seconds>\t<log path>

The full output is `.claude/gates/<sha>.log`. A lock file keeps two runs from
overlapping; a run older than three hours is presumed dead and its lock is
taken over. `--once` runs the check now regardless of the schedule; `--sha`
gates a given commit instead of main's head.
"""
import argparse
import datetime as dt
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATES = os.path.join(ROOT, ".claude", "gates")
STATUS = os.path.join(GATES, "status.tsv")
LOCK = os.path.join(GATES, "gate.lock")
WORKTREE = os.path.join(ROOT, ".claude", "gate-wt")
GATE_RUNNER = "14C70E21-A23A-4492-8E6A-113AE0BC6B6D"
STALE_LOCK_S = 3 * 3600


def git(*args, cwd=ROOT):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def gated():
    if not os.path.exists(STATUS):
        return set()
    with open(STATUS) as fh:
        return {line.split("\t")[0] for line in fh if line.strip()}


def take_lock():
    if os.path.exists(LOCK):
        if time.time() - os.path.getmtime(LOCK) < STALE_LOCK_S:
            return False
        os.remove(LOCK)
    with open(LOCK, "w") as fh:
        fh.write(str(os.getpid()))
    return True


def checkout(sha):
    if os.path.isdir(WORKTREE):
        subprocess.run(["git", "worktree", "remove", "--force", WORKTREE], cwd=ROOT,
                       capture_output=True)
    subprocess.run(["git", "worktree", "prune"], cwd=ROOT, capture_output=True)
    # a directory git no longer knows as a worktree still blocks `worktree add`:
    # Finder drops a .DS_Store into the emptied folder and the gate then fails
    # every run until somebody removes it by hand
    if os.path.isdir(WORKTREE):
        shutil.rmtree(WORKTREE)
    git("worktree", "add", "--detach", WORKTREE, sha)
    # the gitignored pieces a build needs: the server's node_modules (the
    # smoke imports `ws`), and the local signing config when it exists
    for rel in ("server/node_modules", "ios/Config/Signing.xcconfig", "local.mk"):
        src = os.path.join(ROOT, rel)
        dst = os.path.join(WORKTREE, rel)
        if os.path.exists(src) and not os.path.exists(dst):
            os.symlink(src, dst)


def run_gate(sha):
    os.makedirs(GATES, exist_ok=True)
    started = dt.datetime.now().astimezone().replace(microsecond=0).isoformat()
    log = os.path.join(GATES, f"{sha[:12]}.log")
    t0 = time.time()
    checkout(sha)
    with open(log, "w") as fh:
        fh.write(f"== gate {sha} started {started}\n")
        fh.flush()
        result = subprocess.run(["make", "check", f"DEV_UDID={GATE_RUNNER}"], cwd=WORKTREE,
                                stdout=fh, stderr=subprocess.STDOUT)
    verdict = "green" if result.returncode == 0 else "red"
    with open(STATUS, "a") as fh:
        fh.write(f"{sha}\t{started}\t{verdict}\t{int(time.time() - t0)}\t{log}\n")
    subprocess.run(["git", "worktree", "remove", "--force", WORKTREE], cwd=ROOT, capture_output=True)
    return verdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="gate main's head now, even if it was gated")
    ap.add_argument("--sha", help="gate this commit instead of main's head")
    args = ap.parse_args()
    sha = git("rev-parse", args.sha or "main")
    if not args.once and not args.sha and sha in gated():
        return 0
    if not take_lock():
        print("a gate is already running", file=sys.stderr)
        return 0
    try:
        verdict = run_gate(sha)
        print(f"{sha[:12]} {verdict}")
        return 0 if verdict == "green" else 1
    finally:
        if os.path.exists(LOCK):
            os.remove(LOCK)


if __name__ == "__main__":
    sys.exit(main())
