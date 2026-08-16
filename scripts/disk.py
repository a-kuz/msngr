#!/usr/bin/env python3
"""What our footprint on this disk is made of.

    scripts/disk.py          print the last snapshot (instant)
    scripts/disk.py --scan   walk the disk and write a new one (a minute or two)
    scripts/disk.py --json   the snapshot as it is stored

Walking a few hundred thousand simulator files takes long enough that nobody
would run it while looking for an answer, so the walk happens on a schedule and
the reading is a file. The snapshot is stamped, and printing it says how old it
is; free space is the one number read live, because it is a single syscall and
it is the number a decision usually turns on.

Everything is measured once and attributed to exactly one group: a stand inside
a worktree is subtracted from that worktree, `.git` is subtracted from the
checkout. The totals add up to the footprint, so "85 GB" means something.
"""

import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOME = Path.home()


def main_checkout():
    """The main checkout, even when this copy of the script is in a worktree.

    Worktrees share one object store, so the directory holding `.git` is the
    one place where the registry, the stands and the worktree list all live.
    """
    here = Path(__file__).resolve().parent.parent
    common = subprocess.run(
        ["git", "-C", str(here), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True).stdout.strip()
    return Path(common).parent if common else here


ROOT = main_checkout()
SNAPSHOT = ROOT / ".claude" / "disk.json"

# The owner's two devices and the gate runner. Named here so the metric can say
# which simulators are furniture and which are an agent's litter.
KEEP_DEVICES = {
    "44CE2242-EBB9-48EA-A605-5988A00E4C31": "owner",
    "0E0CF155-B4B7-4794-A963-AD7C76EFDCEA": "owner",
    "74B78AFC-E8D7-4317-B16F-E51A65504B2D": "gate",
}
SHARED_STAND = ROOT / "server" / ".wrangler"

RESET, BOLD, DIM = "\033[0m", "\033[1m", "\033[2m"
RED, YELLOW, GREY, GREEN = "\033[31m", "\033[33m", "\033[90m", "\033[32m"


# ---------------------------------------------------------------- measuring

def du_kb(path):
    """Bytes on disk under a path, or 0 if it went away mid-walk."""
    try:
        out = subprocess.run(["du", "-sk", str(path)], capture_output=True,
                             text=True, timeout=900).stdout
        return int(out.split()[0]) * 1024
    except (ValueError, IndexError, subprocess.SubprocessError):
        return 0


def du_all(paths):
    """du over many paths at once; the walk is disk-bound, not CPU-bound."""
    paths = list(paths)
    if not paths:
        return {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        return dict(zip(paths, pool.map(du_kb, paths)))


def free_bytes():
    s = os.statvfs("/System/Volumes/Data")
    return s.f_bavail * s.f_frsize, s.f_blocks * s.f_frsize


# ------------------------------------------------------------- what is ours

TRANSCRIPTS = HOME / ".claude" / "projects"
QUIET = 10 * 60  # a transcript this fresh means somebody is still typing into it


def alive(session):
    """Two independent signs of life, because either one alone misses agents.

    `ps` misses an agent whose session id never made it onto a command line —
    that happens, and the price of believing it is deleting the worktree of
    somebody still working. The transcript is written on every turn, so a file
    touched minutes ago is an agent that has not finished.
    """
    if subprocess.run(["pgrep", "-f", session], capture_output=True).returncode == 0:
        return True
    for path in TRANSCRIPTS.glob(f"*/{session}.jsonl"):
        if time.time() - path.stat().st_mtime < QUIET:
            return True
    return False


def registry():
    """Agents by name, from .claude/agents.tsv, with whether they are alive."""
    path = ROOT / ".claude" / "agents.tsv"
    agents = {}
    if not path.exists():
        return agents
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0].strip():
            continue
        name, session = parts[0].strip(), parts[1].strip()
        agents[name] = {"session": session, "alive": alive(session),
                        "worktree": parts[2].strip() if len(parts) > 2 else ""}
    return agents


def device_owner(name, agents):
    """The agent a simulator belongs to, by the `<agent>-<role>` convention."""
    for agent in agents:
        if name == agent or name.startswith(agent + "-"):
            return agent
    return None


def devices():
    """Every simulator with the size simctl already knows, so no walk needed."""
    try:
        raw = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"],
                             capture_output=True, text=True, timeout=60).stdout
        listing = json.loads(raw)["devices"]
    except (subprocess.SubprocessError, ValueError, KeyError):
        return []
    out = []
    for runtime, group in listing.items():
        for dev in group:
            size = dev.get("dataPathSize") or 0
            if not size and not dev.get("dataPath"):
                continue
            out.append({
                "name": dev.get("name", "?"),
                "udid": dev.get("udid", ""),
                "state": dev.get("state", "?"),
                "runtime": runtime.rsplit(".", 1)[-1],
                "bytes": size,
            })
    return out


def persist_paths():
    """Stand state directories a running wrangler is pointing at."""
    try:
        ps = subprocess.run(["ps", "-eo", "command"], capture_output=True,
                            text=True, timeout=30).stdout
    except subprocess.SubprocessError:
        return set()
    found = set()
    for line in ps.splitlines():
        if "wrangler" not in line:
            continue
        m = re.search(r"--persist-to[= ]+(\S+)", line)
        if m:
            found.add(m.group(1))
    return found


def stand_dirs():
    """Every wrangler state directory we know how to find."""
    out = []
    out += sorted((ROOT / ".claude").glob("stand-*"))
    out += sorted((ROOT / "server").glob(".wrangler*"))
    for wt in sorted((ROOT / ".claude" / "worktrees").glob("*")):
        if wt.is_dir():
            out += sorted((wt / "server").glob(".wrangler*"))
            out += sorted(wt.glob(".scratch/wrangler-state"))
    for p in persist_paths():
        path = Path(p)
        if path.is_dir() and path not in out:
            out.append(path)
    out = [p.resolve() for p in out if p.is_dir()]
    # `--persist-to .claude/stand-8891/state` sits inside `.claude/stand-8891`;
    # counting both would count the state twice and would let the outer one look
    # unused. Only the outermost directory is a stand.
    return sorted({p for p in out
                   if not any(q != p and is_under(p, q) for q in out)})


def is_under(path, parent):
    return str(path).startswith(str(parent) + "/")


def held_by_dead_files():
    """Bytes that df counts and du cannot see: unlinked files still open.

    A stand whose directory was deleted while its wrangler kept running holds
    its whole node_modules this way, and the space comes back only when the
    process does.
    """
    try:
        out = subprocess.run(["lsof", "-nP", "+L1"], capture_output=True,
                             text=True, timeout=180).stdout
    except subprocess.SubprocessError:
        return 0, []
    total, procs = 0, {}
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 8:
            continue
        try:
            size = int(parts[6])
        except ValueError:
            continue
        total += size
        procs[parts[0]] = procs.get(parts[0], 0) + size
    top = sorted(procs.items(), key=lambda kv: -kv[1])[:5]
    return total, [{"name": n, "bytes": b} for n, b in top]


# ------------------------------------------------------------------- a scan

def scan():
    started = time.time()
    agents = registry()
    groups = []

    # Simulators. Size comes from simctl, so this group costs nothing.
    sims = []
    for dev in devices():
        role = KEEP_DEVICES.get(dev["udid"])
        loose = False
        if role:
            note = "owner's device" if role == "owner" else "gate runner"
        else:
            owner = device_owner(dev["name"], agents)
            if owner is None:
                note, loose = "nobody's", True
            elif agents[owner]["alive"]:
                note = f"agent {owner}"
            else:
                note, loose = f"agent {owner}, gone", True
        sims.append({"name": f"{dev['name']} ({dev['state'].lower()})",
                     "bytes": dev["bytes"], "note": note, "loose": loose})
    groups.append({"name": "simulators", "items": sims})

    # Stands, measured before the worktrees so they can be subtracted from them.
    stands = stand_dirs()
    stand_size = du_all(stands)
    live = {Path(p).resolve() for p in persist_paths() if Path(p).is_dir()}
    stand_items = []
    for path in stands:
        loose = False
        if path == SHARED_STAND.resolve():
            note = "the shared :8787 stand"
        elif any(p == path or is_under(p, path) for p in live):
            note = "a running stand"
        else:
            note, loose = "no process holds it", True
        stand_items.append({"name": str(path).replace(str(ROOT) + "/", ""),
                            "bytes": stand_size[path], "note": note,
                            "loose": loose, "path": str(path)})
    groups.append({"name": "stands", "items": stand_items})

    # Worktrees, each without the stand state that sits inside it.
    trees = [p for p in sorted((ROOT / ".claude" / "worktrees").glob("*")) if p.is_dir()]
    tree_size = du_all(trees)
    tree_items = []
    for tree in trees:
        inner = sum(stand_size[s] for s in stands if is_under(s, tree.resolve()))
        branch = tree.name
        owner = next((n for n, a in agents.items() if a["worktree"] == branch), None)
        loose = False
        if owner and agents[owner]["alive"]:
            note = f"agent {owner}"
        elif merged(branch):
            note, loose = "branch merged", True
        else:
            note = "branch not merged"
        tree_items.append({"name": tree.name, "bytes": max(0, tree_size[tree] - inner),
                           "note": note, "loose": loose, "path": str(tree)})
    groups.append({"name": "worktrees", "items": tree_items})

    # Derived data, per project, with the workspace it was built from.
    dd = HOME / "Library" / "Developer" / "Xcode" / "DerivedData"
    dd_dirs = [p for p in sorted(dd.glob("*")) if p.is_dir()]
    dd_size = du_all(dd_dirs)
    dd_items = []
    for path in dd_dirs:
        loose = False
        if path.name.endswith(".noindex"):
            note = "shared build cache"
        else:
            ws = workspace_of(path)
            if ws and not Path(ws).exists():
                note, loose = "workspace gone", True
            else:
                note = "in use"
        dd_items.append({"name": path.name, "bytes": dd_size[path], "note": note,
                         "loose": loose, "path": str(path)})
    groups.append({"name": "derived data", "items": dd_items})

    # Caches nothing owns: they rebuild themselves and cost only time.
    caches = {
        "simulator runtimes and caches": HOME / "Library/Developer/CoreSimulator/Caches",
        "device support": HOME / "Library/Developer/Xcode/iOS DeviceSupport",
        "xcode archives": HOME / "Library/Developer/Xcode/Archives",
        "swiftpm cache": HOME / "Library/Caches/org.swift.swiftpm",
        "simulator temp": HOME / "Library/Developer/CoreSimulator/Temp",
    }
    cache_size = du_all([p for p in caches.values() if p.exists()])
    groups.append({"name": "caches", "items": [
        {"name": name, "bytes": cache_size.get(path, 0), "note": "rebuilds itself",
         "path": str(path)}
        for name, path in caches.items() if path.exists()]})

    # The checkout itself, split so `.git` does not hide inside it.
    git_dir = ROOT / ".git"
    checkout = du_all([ROOT, git_dir, ROOT / ".claude"])
    claude_own = sum(s["bytes"] for s in stand_items if s["path"].startswith(str(ROOT / ".claude")))
    claude_own += sum(t["bytes"] for t in tree_items)
    logs = du_all([ROOT / ".claude" / "logs", ROOT / ".claude" / "agent-runs"]
                  + sorted((ROOT / ".claude").glob("scratch-*")))
    groups.append({"name": "the checkout", "items": [
        {"name": "working tree", "bytes": max(0, checkout[ROOT] - checkout[git_dir] - checkout[ROOT / ".claude"]),
         "note": "sources and node_modules"},
        {"name": ".git", "bytes": checkout[git_dir], "note": "shared by every worktree"},
    ]})
    groups.append({"name": "logs and scratch", "items": [
        {"name": str(p).replace(str(ROOT) + "/", ""), "bytes": b, "note": "",
         "path": str(p)}
        for p, b in sorted(logs.items(), key=lambda kv: -kv[1])]})

    dead_bytes, dead_procs = held_by_dead_files()
    avail, total = free_bytes()
    snapshot = {
        "taken": int(time.time()),
        "took_s": round(time.time() - started, 1),
        "disk": {"total": total, "free": avail},
        "footprint": sum(i["bytes"] for g in groups for i in g["items"]),
        "held_by_dead_files": {"bytes": dead_bytes, "processes": dead_procs},
        "groups": groups,
    }
    SNAPSHOT.parent.mkdir(parents=True, exist_ok=True)
    SNAPSHOT.write_text(json.dumps(snapshot, indent=1))
    return snapshot


def merged(branch):
    out = subprocess.run(["git", "-C", str(ROOT), "branch", "--merged", "main"],
                         capture_output=True, text=True).stdout
    return branch in {l.strip("* +").strip() for l in out.splitlines()}


def workspace_of(path):
    plist = path / "info.plist"
    if not plist.exists():
        return None
    m = re.search(r"WorkspacePath</key>\s*<string>(.*?)</string>",
                  plist.read_text(errors="ignore"), re.S)
    return m.group(1) if m else None


# ----------------------------------------------------------------- printing

def gb(n):
    return f"{n / 2**30:6.2f}G"


def ago(seconds):
    seconds = int(seconds)
    if seconds < 90:
        return f"{seconds}s"
    if seconds < 5400:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def show(snap):
    avail, total = free_bytes()
    age = time.time() - snap["taken"]
    stale = RED if age > 3 * 3600 else (YELLOW if age > 3600 else GREY)
    loose = sum(i["bytes"] for g in snap["groups"] for i in g["items"] if i.get("loose"))
    print(f"{BOLD}footprint {gb(snap['footprint']).strip()}{RESET}"
          f"  {stale}snapshot {ago(age)} old, took {snap['took_s']}s{RESET}"
          f"  {DIM}free {gb(avail).strip()} of {gb(total).strip()} (live){RESET}")
    print(f"{DIM}{gb(loose).strip()} of it is loose — nothing alive holds it{RESET}\n")

    for group in sorted(snap["groups"], key=lambda g: -sum(i["bytes"] for i in g["items"])):
        items = sorted(group["items"], key=lambda i: -i["bytes"])
        if not items:
            continue
        total_g = sum(i["bytes"] for i in items)
        print(f"{BOLD}{gb(total_g)}  {group['name']}{RESET}")
        hidden = 0
        for item in items:
            note = item.get("note", "")
            spare = not item.get("loose")
            # Small things are noise unless the reaper has an opinion about them.
            if item["bytes"] < 20 * 2**20 and spare:
                hidden += 1
                continue
            colour = GREY if spare else RED
            name = item["name"]
            if len(name) > 52:
                name = "…" + name[-51:]
            print(f"  {gb(item['bytes'])}  {name:<52}{colour}{note}{RESET}")
        if hidden:
            print(f"  {DIM}and {hidden} smaller{RESET}")
        print()

    dead = snap.get("held_by_dead_files", {})
    if dead.get("bytes", 0) > 2**30:
        who = ", ".join(f"{p['name']} {gb(p['bytes']).strip()}" for p in dead["processes"])
        print(f"{YELLOW}{gb(dead['bytes'])}  held by deleted files still open{RESET}  {DIM}{who}{RESET}")
        print(f"  {DIM}du cannot see it; it comes back when those processes do{RESET}\n")


def main():
    args = sys.argv[1:]
    if "--scan" in args:
        snap = scan()
    else:
        if not SNAPSHOT.exists():
            print("no snapshot yet — run scripts/disk.py --scan", file=sys.stderr)
            return 1
        snap = json.loads(SNAPSHOT.read_text())
    if "--json" in args:
        json.dump(snap, sys.stdout, indent=1)
        print()
    else:
        show(snap)
    return 0


if __name__ == "__main__":
    sys.exit(main())
