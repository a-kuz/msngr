#!/usr/bin/env python3
"""Takes back what dead agents left behind, and asks when that is not enough.

    scripts/tidy.py            what would go
    scripts/tidy.py --apply    let it go
    scripts/tidy.py --report   write the escalation report whatever the free space

Runs from launchd every five minutes (`ai.enface.msngr.tidy`). Everything it
removes on its own has been checked to belong to nobody: the agent that made it
is gone, or no process is holding it. Nothing here waits for a simulator to be
shut down first, because the shutdown was the dead agent's job and it never
happened — that is the whole reason this exists.

An agent owns a simulator whose name is its own name or starts with it and a
dash: `perfdb` owns `perfdb-a` and `perfdb-b`. Agents are listed in
.claude/agents.tsv, and an agent that never got there is still recognised by a
session writing into a worktree of that name. A name neither of those claims is
left alone for as long as its app keeps writing, and taken once it stops.

Two things are never touched: the owner's two devices with the gate runner, and
the shared stand on :8787 with the conversations and keys in server/.wrangler.

When the sweep cannot get free space above the floor, the decision stops being
ours. The report says what is holding the disk and what would be next to go,
and it comes with a notification instead of a silent stall.
"""

import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # a cleaner does not leave a __pycache__ behind
sys.path.insert(0, str(Path(__file__).resolve().parent))
import disk  # noqa: E402  the metric and the facts about what belongs to whom

ROOT = disk.ROOT
REPORT = ROOT / ".claude" / "disk-report.md"

FLOOR = int(os.environ.get("TIDY_FLOOR_GB", 25)) * 2**30   # ask below this
BUDGET = int(os.environ.get("TIDY_BUDGET_GB", 85)) * 2**30  # what we said we'd fit in
# A thing has to be still for this long before it counts as litter. Lowering it
# is how the sweep gets tested without waiting half an hour for the clock.
SETTLE = int(os.environ.get("TIDY_SETTLE_MIN", 30)) * 60
# A live agent's simulator is shut down (not deleted) after this much quiet: it
# holds gigabytes of memory while it is up, and booting it back costs seconds.
IDLE_BOOT = int(os.environ.get("TIDY_IDLE_BOOT_MIN", 20)) * 60
SNAPSHOT_MAX_AGE = 15 * 60

APPLY = "--apply" in sys.argv


def log(line):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {line}", flush=True)


# --------------------------------------------------------------- candidates

def newest_write(path, cap=20000):
    """When anything under a path was last written. Cheap enough to call often."""
    newest = 0
    seen = 0
    for root, dirs, files in os.walk(path, onerror=lambda e: None):
        for name in files:
            try:
                newest = max(newest, os.lstat(os.path.join(root, name)).st_mtime)
            except OSError:
                pass
            seen += 1
            if seen > cap:
                return newest
    return newest


def quiet_for(path):
    last = newest_write(path)
    return time.time() - last if last else float("inf")


def app_group_id():
    """The app group both the app and the extension write into."""
    entitlements = ROOT / "ios" / "project.yml"
    if entitlements.exists():
        for line in entitlements.read_text().splitlines():
            if "application-groups" in line and "[" in line:
                return line.split("[", 1)[1].split("]")[0].split(",")[0].strip()
    return "group.ai.enface.msngr"


def app_quiet_for(udid):
    """How long our own app has been silent on a simulator.

    A booted simulator writes to `data/Containers` forever on its own — Siri,
    news, splash screens, a few dozen system group containers — so the tree as
    a whole says nothing about whether anyone is using it. Our app group is
    written by our app and the extension and by nothing else, which is what
    makes it an answer.
    """
    shared = disk.DEVICES / udid / "data" / "Containers" / "Shared" / "AppGroup"
    if not shared.is_dir():
        return float("inf")
    wanted = app_group_id()
    for path in shared.iterdir():
        meta = path / ".com.apple.mobile_container_manager.metadata.plist"
        if not meta.exists():
            continue
        try:
            with meta.open("rb") as f:
                if plistlib.load(f).get("MCMMetadataIdentifier") != wanted:
                    continue
        except (OSError, ValueError):
            continue
        return quiet_for(path)
    return float("inf")


def stale_simulators(agents, working):
    """Simulators no live agent claims, that have also stopped writing.

    The registry decides ownership, but an agent that never registered would
    lose its work to that alone, so the container has to be still as well. A
    device that is unclaimed and busy is left for the report to raise.
    """
    out, busy = [], []
    for dev in disk.devices():
        note, loose = disk.claim(dev, agents, working)
        if not loose:
            continue
        home = disk.DEVICES / dev["udid"]
        if not home.exists():
            continue
        if time.time() - home.stat().st_ctime < SETTLE:
            continue
        if note.endswith(", gone"):
            # The registry named this agent and the agent has finished. Nothing
            # else has to agree: an abandoned app keeps writing for as long as
            # the simulator is up — one left a trace file ticking every second
            # hours after its agent was gone — so waiting for quiet here would
            # be waiting forever.
            why = f"agent {note.split()[1].rstrip(',')} is gone"
        else:
            # Nobody claims this name at all, which is also what an agent that
            # never registered looks like. Its app would still be writing.
            idle = app_quiet_for(dev["udid"])
            if idle < SETTLE:
                busy.append((dev, f"nothing claims {dev['name']}, and its app "
                             f"was writing {int(idle / 60)}m ago"))
                continue
            why = f"nothing claims {dev['name']}, and its app has been quiet"
        out.append({"what": f"simulator {dev['name']}", "bytes": dev["bytes"],
                    "why": why, "do": lambda u=dev["udid"]: delete_device(u)})
    return out, busy


def delete_device(udid):
    subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
    subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)


def idle_booted(agents, working):
    """Booted simulators of live agents that nobody has touched for a while.

    A simulator costs two to four gigabytes of memory while it is up, and a host
    running five agents ran out: free memory fell to sixty megabytes and the
    machine spent its time swapping, with the CPU idle. Shutting one down loses
    nothing — the device, its app and its data stay, and the next `simctl boot`
    brings it back — so an agent that comes back to a still simulator pays a boot
    and the rest of the host gets its memory back.
    """
    out = []
    for dev in disk.devices():
        if dev.get("state") != "Booted" or dev["udid"] in disk.KEEP_DEVICES:
            continue
        note, loose = disk.claim(dev, agents, working)
        if loose:
            continue  # the litter rules own this one
        idle = app_quiet_for(dev["udid"])
        if idle < IDLE_BOOT:
            continue
        out.append({"what": f"simulator {dev['name']}", "bytes": 0,
                    "why": f"{note}, app quiet for {int(idle / 60)}m",
                    "verb": ("shut down", "would shut down"),
                    "do": lambda u=dev["udid"]: subprocess.run(
                        ["xcrun", "simctl", "shutdown", u], capture_output=True)})
    return out


def stale_stands(working):
    """Stand state directories with no wrangler pointing at them."""
    live = {Path(p).resolve() for p in disk.persist_paths() if Path(p).is_dir()}
    shared = disk.SHARED_STAND.resolve()
    busy = list(working.values())
    out = []
    for path in disk.stand_dirs():
        if path == shared or any(p == path or disk.is_under(p, path) for p in live):
            continue
        # A working agent's own stand is left alone even between its wrangler
        # runs: it is empty for a moment, not abandoned.
        if any(disk.is_under(path, tree) for tree in busy):
            continue
        if quiet_for(path) < SETTLE:
            continue
        out.append({"what": f"stand {rel(path)}", "bytes": disk.du_kb(path),
                    "why": "no wrangler is holding it",
                    "do": lambda p=path: shutil.rmtree(p, ignore_errors=True)})
    return out


def orphan_stand_processes():
    """Wranglers whose worktree was deleted under them.

    They keep running against files that no longer have a name, so the space
    shows in df and in nothing else. Killing the process is what frees it.
    """
    try:
        ps = subprocess.run(["ps", "-eo", "pid,command"], capture_output=True,
                            text=True, timeout=30).stdout
    except subprocess.SubprocessError:
        return []
    trees = re.escape(str(ROOT / ".claude" / "worktrees"))
    inside = re.compile(trees + r"/([^/\s]+)/")
    dead, ports = {}, {}
    for line in ps.splitlines()[1:]:
        pid, _, command = line.strip().partition(" ")
        # Only the program and the script it was given, never the whole line:
        # an agent is started with its worktree path written out in the prompt,
        # and matching that would have this kill the agent itself.
        head = " ".join(command.split()[:2])
        if not any(k in head for k in ("wrangler", "workerd", "esbuild")):
            continue
        found = inside.search(head)
        if not found:
            continue
        tree = found.group(1)
        if (ROOT / ".claude" / "worktrees" / tree).exists():
            continue
        dead.setdefault(tree, []).append(int(pid))
        port = re.search(r"--port[= ]+(\d+)", command)
        if port:
            ports.setdefault(tree, set()).add(int(port.group(1)))
    out = []
    for tree, pids in sorted(dead.items()):
        if any(has_clients(port) for port in ports.get(tree, ())):
            continue
        out.append({"what": f"the stand of the deleted worktree {tree} "
                            f"({len(pids)} processes)",
                    "bytes": 0, "why": "it is holding files that no longer exist",
                    "do": lambda p=pids: kill(p)})
    return out


def socket_hogs(limit=2000):
    """Stands that have stopped closing their sockets.

    One seeding run left a workerd holding 26 854 loopback sockets, 14 485 of them
    in CLOSE_WAIT, against the 16 384 ephemeral ports the machine has. Everything
    that needed a new connection then hung, the shared stand included, and the
    host looked like it was out of memory. A stand past this many sockets is
    already broken, so killing it takes nothing away and gives the ports back.
    """
    try:
        out = subprocess.run(["lsof", "-nP", "-i", "TCP"], capture_output=True,
                             text=True, timeout=120).stdout
    except subprocess.SubprocessError:
        return []
    count = {}
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) > 1 and parts[0] == "workerd":
            count[int(parts[1])] = count.get(int(parts[1]), 0) + 1
    plan = []
    for pid, sockets in sorted(count.items()):
        if sockets < limit:
            continue
        plan.append({"what": f"stand process {pid}", "bytes": 0,
                     "verb": ("killed", "would kill"),
                     "why": f"holding {sockets} sockets, the host has 16384 ports",
                     "do": lambda p=pid: kill([p])})
    return plan


def has_clients(port):
    """Whether anybody is connected to the port a stand serves.

    Asking about the processes instead would always say yes: wrangler runs node
    and workerd as a pair and they hold loopback sockets to each other for as
    long as they live. The served port is the one an app connects to.
    """
    try:
        out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:ESTABLISHED"],
                             capture_output=True, text=True, timeout=60).stdout
    except subprocess.SubprocessError:
        return True
    return len(out.splitlines()) > 1


def kill(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass


def merged_worktrees(agents, working):
    """Worktrees whose branch is in main, with nothing left in them to lose."""
    owned = {a["worktree"] for a in agents.values() if a["alive"]}
    owned |= {p.name for p in working.values()}
    here = Path.cwd().resolve()
    cwds = process_cwds()
    out = []
    trees = ROOT / ".claude" / "worktrees"
    for path in sorted(trees.glob("*")) if trees.is_dir() else []:
        if not path.is_dir() or path.name in owned:
            continue
        full = path.resolve()
        if full == here or disk.is_under(here, full):
            continue
        if any(c == full or disk.is_under(c, full) for c in cwds):
            continue
        if not disk.merged(path.name):
            continue
        dirty = subprocess.run(["git", "-C", str(path), "status", "--porcelain"],
                               capture_output=True, text=True).stdout.strip()
        if dirty:
            continue
        out.append({"what": f"worktree {path.name}", "bytes": disk.du_kb(path),
                    "why": "branch merged, nothing uncommitted, nobody in it",
                    "do": lambda p=path: remove_worktree(p)})
    return out


def process_cwds():
    """Directories processes are sitting in, so a worktree in use is not removed."""
    try:
        out = subprocess.run(["lsof", "-a", "-d", "cwd", "-n", "-F", "n"],
                             capture_output=True, text=True, timeout=120).stdout
    except subprocess.SubprocessError:
        return set()
    return {Path(line[1:]) for line in out.splitlines()
            if line.startswith("n/") and "/worktrees/" in line}


def remove_worktree(path):
    done = subprocess.run(["git", "-C", str(ROOT), "worktree", "remove",
                           str(path), "--force"], capture_output=True)
    if done.returncode != 0:
        shutil.rmtree(path, ignore_errors=True)
    subprocess.run(["git", "-C", str(ROOT), "worktree", "prune"], capture_output=True)


def orphan_derived_data():
    """Derived data built from a workspace that is no longer there."""
    out = []
    root = disk.HOME / "Library" / "Developer" / "Xcode" / "DerivedData"
    for path in sorted(root.glob("*")) if root.is_dir() else []:
        if not path.is_dir() or path.name.endswith(".noindex"):
            continue
        workspace = disk.workspace_of(path)
        if not workspace or Path(workspace).exists():
            continue
        out.append({"what": f"derived data {path.name}", "bytes": disk.du_kb(path),
                    "why": f"built from {workspace}, which is gone",
                    "do": lambda p=path: shutil.rmtree(p, ignore_errors=True)})
    return out


def old_logs(days=3):
    """Run logs older than a few days. Nobody has ever read one that old."""
    cutoff = time.time() - days * 86400
    out = []
    for folder in ((ROOT / ".claude" / "logs"), (ROOT / ".claude" / "agent-runs")):
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob("*")):
            if not path.is_file() or path.stat().st_mtime > cutoff:
                continue
            out.append({"what": f"log {rel(path)}", "bytes": path.stat().st_size,
                        "why": f"older than {days} days",
                        "do": lambda p=path: p.unlink(missing_ok=True)})
    return out


def rel(path):
    return str(path).replace(str(ROOT) + "/", "")


# ------------------------------------------------------------------ the run

def sweep():
    agents = disk.registry()
    working = disk.live_worktrees()
    sims, busy = stale_simulators(agents, working)
    plan = list(sims)
    # One rule tripping over a file that moved under it must not cost the run:
    # this is a cron job, and the next thing after it is the escalation check.
    for rule in (lambda: idle_booted(agents, working),
                 socket_hogs,
                 lambda: stale_stands(working),
                 orphan_stand_processes,
                 lambda: merged_worktrees(agents, working),
                 orphan_derived_data,
                 old_logs):
        try:
            plan += rule()
        except OSError as err:
            log(f"rule failed, skipped: {err}")
    freed = 0
    for item in plan:
        size = f"{item['bytes'] / 2**30:.2f}G" if item["bytes"] else "—"
        did, would = item.get("verb", ("removed", "would remove"))
        if APPLY:
            try:
                item["do"]()
            except OSError as err:
                log(f"could not touch {item['what']}: {err}")
                continue
            log(f"{did} {item['what']} ({size}) — {item['why']}")
            freed += item["bytes"]
        else:
            log(f"{would} {item['what']} ({size}) — {item['why']}")
    return plan, busy, freed


# --------------------------------------------------------------- escalation

def gb(n):
    return f"{n / 2**30:.1f} GB"


def proposals(snap, busy):
    """What a human could give up next, dearest first, with what it costs.

    Only things a script must not take on its own: work in progress, state with
    test users in it, caches whose loss is measured in build minutes.
    """
    out = []
    for group in snap["groups"]:
        for item in group["items"]:
            if item.get("loose") or item["bytes"] < 200 * 2**20:
                continue
            name, size = item["name"], item["bytes"]
            if group["name"] == "derived data" and name.endswith(".noindex"):
                out.append((size, f"`{name}` — a shared build cache. Costs one "
                            "cold build of every scheme."))
            elif group["name"] == "derived data":
                out.append((size, f"derived data `{name}` — costs one cold "
                            "build of that project."))
            elif group["name"] == "simulators" and item["note"].startswith("agent "):
                out.append((size, f"simulator `{item.get('device', name)}` "
                            f"belongs to a working {item['note']}. Ask it to "
                            "finish first."))
            elif group["name"] == "logs and scratch":
                out.append((size, f"`{name}` — scratch of a run that ended."))
            elif name == "swiftpm cache":
                out.append((size, "the SwiftPM cache — costs one re-resolve of "
                            "the packages."))
            elif name.endswith("server/.wrangler"):
                out.append((size, "`server/.wrangler` — the shared stand. It "
                            "holds the conversations and keys of the test "
                            "users; deleting it means registering them again."))
    out.sort(key=lambda p: -p[0])

    # A simulator nobody claims that is still being written to comes first
    # whatever its size: it is the one thing here that should not exist at all.
    head = [(dev["bytes"], f"simulator `{dev['name']}` — {why}. Nothing in the "
             "registry claims it, so either an agent is running unregistered or "
             "it was left behind. `xcrun simctl delete` takes it.")
            for dev, why in busy]

    dead = snap.get("held_by_dead_files", {}).get("bytes", 0)
    if dead > 2 * 2**30:
        who = ", ".join(p["name"] for p in snap["held_by_dead_files"]["processes"][:3])
        head.append((dead, f"{gb(dead)} is held by deleted files still open "
                     f"({who}). Restarting those processes returns it and "
                     "deletes nothing."))
    head.sort(key=lambda p: -p[0])
    return (head + out)[:10]


def escalate(snap, busy, freed):
    avail, total = disk.free_bytes()
    lines = [
        "# The sweep was not enough",
        "",
        f"Written by `scripts/tidy.py` at {time.strftime('%Y-%m-%d %H:%M')}. "
        f"Free space is {gb(avail)} of {gb(total)}, and the floor this asks at "
        f"is {gb(FLOOR)}. The sweep just before this "
        + (f"took back {gb(freed)}" if APPLY else "was a dry run")
        + "; everything left needs somebody to decide.",
        "",
        "## Where the space is",
        "",
    ]
    for group in sorted(snap["groups"], key=lambda g: -sum(i["bytes"] for i in g["items"])):
        size = sum(i["bytes"] for i in group["items"])
        if size < 200 * 2**20:
            continue
        biggest = sorted(group["items"], key=lambda i: -i["bytes"])[:3]
        detail = ", ".join(f"{i['name']} {gb(i['bytes'])}" for i in biggest)
        lines.append(f"- **{group['name']}** {gb(size)} — {detail}")
    beyond = (snap.get("outside") or {}).get("items") or []
    if beyond:
        theirs = ", ".join(
            f"`{i['name']}` {gb(i['bytes'] - i.get('mine', 0))}"
            for i in beyond[:3] if i["bytes"] - i.get("mine", 0) > 2**30)
        lines += ["", f"Our whole footprint is {gb(snap['footprint'])} of the "
                  f"{gb(total - avail)} in use on this disk. The rest is "
                  f"somebody else's: {theirs}."]

    lines += ["", "## What could go next", ""]
    for size, text in proposals(snap, busy):
        lines.append(f"- {gb(size)} — {text}")
    lines += ["", "Nothing above was touched. `scripts/disk.py` prints the "
              "current picture; `scripts/tidy.py` without `--apply` prints what "
              "it would take on its own."]

    REPORT.write_text("\n".join(lines) + "\n")
    log(f"free space {gb(avail)} is below the floor {gb(FLOOR)} — wrote {rel(REPORT)}")
    notify(f"Free space {gb(avail)}. The sweep took back {gb(freed)} and cannot "
           f"reach {gb(FLOOR)}. See .claude/disk-report.md")


def notify(text):
    body = text.replace('"', "'")
    subprocess.run(["osascript", "-e",
                    f'display notification "{body}" with title "msngr disk"'],
                   capture_output=True)


# ---------------------------------------------------------------------- run

def main():
    plan, busy, freed = sweep()

    stamp = disk.SNAPSHOT
    stale = (not stamp.exists()
             or time.time() - stamp.stat().st_mtime > SNAPSHOT_MAX_AGE)
    snap = None
    if APPLY and (stale or freed):
        snap = disk.scan()

    avail, _ = disk.free_bytes()
    if APPLY:
        # One line every run, even an empty one: a cron that prints nothing when
        # it works reads exactly like a cron that is not running.
        took = f"took back {gb(freed)}" if freed else "nothing to take"
        log(f"swept: {took}, {len(busy)} left for the report, free {gb(avail)}")
    over_budget = snap and snap["footprint"] > BUDGET
    if avail < FLOOR or over_budget or "--report" in sys.argv:
        # The report is about to name the biggest directories on the disk, so
        # it is worth the walk if that part of the snapshot has gone stale.
        if snap is None or not (snap.get("outside") or {}).get("items"):
            snap = disk.scan()
        if over_budget:
            log(f"footprint {gb(snap['footprint'])} is over the "
                f"{gb(BUDGET)} we said we would fit in")
        escalate(snap, busy, freed)
    elif not APPLY:
        log(f"free {gb(avail)}, floor {gb(FLOOR)} — nothing to escalate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
