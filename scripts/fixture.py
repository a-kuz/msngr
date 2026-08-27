#!/usr/bin/env python3
"""Service accounts on a simulator, without registering anybody.

Three accounts — alfa, bravo, charlie — live on the shared stand with three
direct chats between them and three groups, all with history. Each one's device
state is a directory under `.claude/fixtures/`, holding exactly what the app
keeps in its container: `msngr.sqlite`, `.masterkey`, `session.json`. Handing one
to a simulator is a file copy, so the app opens on the chat list instead of the
registration screen.

    scripts/fixture.py seed                      # build them (once, or after --reset)
    scripts/fixture.py install alfa <udid>       # log that simulator in as alfa
    scripts/fixture.py grant <udid>              # permissions only, no account
    scripts/fixture.py pull alfa <udid>          # take the device's state back
    scripts/fixture.py show

The keys of a device belong to one device. Two simulators running the same home
each move the ratchet on their own, and whichever writes second sends a message
the other cannot open — so a home goes to one simulator at a time, and `pull`
brings the moved-on state back before it is handed out again. When a pair has
drifted apart anyway, `seed --reset` builds a fresh trio.
"""

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / ".claude" / "fixtures"
KIT = ROOT / "ios" / "MsngrKit"
GRANT_BLOB = ROOT / "scripts" / "assets" / "notification-grant.bplist"

BUNDLE_ID = os.environ.get("MSNGR_APP_ID", "msngr.msngr")
GROUP_ID = "group.msngr.msngr"
NAMES = ["alfa", "bravo", "charlie"]
# what the app keeps in the group container; the journal is checkpointed into
# the database before a home is written, so these three files are the whole state
STATE_FILES = ["msngr.sqlite", ".masterkey", "session.json"]


def run(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def simctl(*args):
    return run(["xcrun", "simctl", *args])


def die(message):
    print(f"fixture: {message}", file=sys.stderr)
    sys.exit(1)


def booted(udid):
    out = simctl("list", "devices").stdout
    return any(udid in line and "Booted" in line for line in out.splitlines())


def ensure_booted(udid):
    if booted(udid):
        return
    simctl("boot", udid)
    simctl("bootstatus", udid, "-b")


def group_container(udid):
    r = simctl("get_app_container", udid, BUNDLE_ID, GROUP_ID)
    if r.returncode != 0:
        die(f"{BUNDLE_ID} is not installed on {udid}: install the app first "
            f"(xcrun simctl install {udid} <path to Msngr.app>)")
    return Path(r.stdout.strip())


def device_data(udid):
    return Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data"


def grant(udid):
    """Everything the app asks for on a first run: the privacy services simctl
    knows, and the notification authorisation it does not — that one is a
    section in BulletinBoard's own store, taken from a device where it was
    granted by hand.

    The store is read when the daemons come up, so a device that is already
    running is restarted; killing usernotificationsd alone leaves the old
    answer in place and the app still asks (measured on 2026-08-20)."""
    ensure_booted(udid)
    r = simctl("privacy", udid, "grant", "all", BUNDLE_ID)
    if r.returncode != 0:
        die(f"privacy grant failed: {r.stderr.strip()}")

    if not GRANT_BLOB.exists():
        die(f"{GRANT_BLOB} is missing, so notifications cannot be pre-granted")
    store = device_data(udid) / "Library/BulletinBoard/VersionedSectionInfo.plist"
    store.parent.mkdir(parents=True, exist_ok=True)
    data = {"sectionInfo": {}, "sectionInfoVersionNumber": 2}
    if store.exists():
        with store.open("rb") as f:
            data = plistlib.load(f)
    blob = GRANT_BLOB.read_bytes()
    sections = data.setdefault("sectionInfo", {})
    if sections.get(BUNDLE_ID) != blob:
        sections[BUNDLE_ID] = blob
        with store.open("wb") as f:
            plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
        # the daemon has to adopt the section while it is running, or the next
        # boot writes the store back without it; the reboot after that is what
        # makes the app's own request find an answer already there
        simctl("spawn", udid, "launchctl", "kill", "9", "system/com.apple.usernotificationsd")
        time.sleep(3)
        reboot(udid)
    print(f"granted: privacy services and notifications for {BUNDLE_ID}")


def reboot(udid):
    simctl("terminate", udid, BUNDLE_ID)
    simctl("shutdown", udid)
    time.sleep(1)
    simctl("boot", udid)
    simctl("bootstatus", udid, "-b")


def home_of(name):
    home = FIXTURES / name
    if not (home / "session.json").exists():
        die(f"{name} is not seeded; run scripts/fixture.py seed")
    return home


def install(name, udid, launch):
    home = home_of(name)
    ensure_booted(udid)
    container = group_container(udid)
    simctl("terminate", udid, BUNDLE_ID)
    for f in STATE_FILES:
        shutil.copy2(home / f, container / f)
    # the journal of whoever was here before describes a database that has gone
    for stale in ("msngr.sqlite-wal", "msngr.sqlite-shm"):
        (container / stale).unlink(missing_ok=True)
    grant(udid)
    meta = json.loads((home / "meta.json").read_text())
    print(f"{udid} is now {meta['username']} ({meta['userId']})")
    if launch:
        r = simctl("launch", udid, BUNDLE_ID)
        if r.returncode != 0:
            die(f"launch failed: {r.stderr.strip()}")
        print(r.stdout.strip())
    else:
        print(f"launch it with: xcrun simctl launch {udid} {BUNDLE_ID}")


def pull(name, udid):
    """Takes the device's state back into the fixture, so the next hand-out
    starts where this run left off instead of behind it."""
    home = home_of(name)
    container = group_container(udid)
    simctl("terminate", udid, BUNDLE_ID)
    time.sleep(1)
    live = container / "msngr.sqlite"
    if not live.exists():
        die(f"{udid} has no database in its group container")
    # sqlite folds the journal back in, which a plain copy of the file would miss
    r = run(["sqlite3", str(live), "PRAGMA wal_checkpoint(TRUNCATE);"])
    if r.returncode != 0:
        die(f"checkpoint failed: {r.stderr.strip()}")
    for f in STATE_FILES:
        src = container / f
        if src.exists():
            shutil.copy2(src, home / f)
    print(f"{name} now holds what {udid} had")


def seed(base, reset):
    args = ["swift", "run", "msngrfixture", "seed", "--dir", str(FIXTURES), "--base", base]
    if reset:
        args.append("--reset")
    slot = ROOT / "scripts" / "build-slot.py"
    proc = subprocess.run([sys.executable, str(slot), *args], cwd=KIT)
    sys.exit(proc.returncode)


def show():
    for name in NAMES:
        meta = FIXTURES / name / "meta.json"
        if not meta.exists():
            print(f"{name}: not seeded")
            continue
        m = json.loads(meta.read_text())
        print(f"{m['username']}: {m['userId']} — {FIXTURES / name}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("seed", help="build the three accounts and their chats")
    s.add_argument("--base", default=os.environ.get("MSNGR_SERVER", "http://localhost:8787"))
    s.add_argument("--reset", action="store_true", help="throw the current trio away first")

    i = sub.add_parser("install", help="log a simulator in as one of them")
    i.add_argument("name", choices=NAMES)
    i.add_argument("udid")
    i.add_argument("--launch", action="store_true", help="start the app straight away")

    g = sub.add_parser("grant", help="pre-grant permissions on a simulator")
    g.add_argument("udid")

    u = sub.add_parser("pull", help="take a simulator's state back into the fixture")
    u.add_argument("name", choices=NAMES)
    u.add_argument("udid")

    sub.add_parser("show", help="what is seeded")

    a = p.parse_args()
    if a.cmd == "seed":
        seed(a.base, a.reset)
    elif a.cmd == "install":
        install(a.name, a.udid, a.launch)
    elif a.cmd == "grant":
        grant(a.udid)
    elif a.cmd == "pull":
        pull(a.name, a.udid)
    else:
        show()


if __name__ == "__main__":
    main()
