#!/usr/bin/env python3
"""Run a build under one of a few shared slots, so the host is not stormed.

Every agent builds the same project on the same machine. Six xcodebuilds at once
put the load average past 600 and made the tests fail on timing rather than on
code. This holds a slot for the duration of one command:

    scripts/build-slot.py xcodebuild -project ios/Msngr.xcodeproj … test

Slots are advisory locks in a fixed directory, so an agent that dies releases its
slot with its process. MSNGR_BUILD_SLOTS sets how many run at once.
"""

import fcntl
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SLOTS = int(os.environ.get("MSNGR_BUILD_SLOTS") or 2)
DIR = Path.home() / ".msngr-build-slots"
REPORT_EVERY = 30


def take_device(args):
    """One test run per simulator, however many slots the host has.

    A slot is a host resource; a simulator is not. Two agents once took a slot
    each and drove xcodebuild at the same device, reinstalling the app under
    each other's UI tests — every test died with "crashed with signal kill" and
    the device took the blame. The lock is keyed by the UDID in -destination
    and held for the duration of the command, released with the process.
    """
    m = re.search(r"id=([0-9A-F-]{36})", " ".join(args))
    if not m:
        return None
    DIR.mkdir(exist_ok=True)
    handle = (DIR / f"device-{m.group(1)}").open("a+")
    waited = 0
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            handle.seek(0)
            handle.truncate()
            handle.write(f"{os.getpid()} {' '.join(args)[:200]}\n")
            handle.flush()
            return handle
        except OSError:
            if waited % REPORT_EVERY == 0:
                holder = (DIR / f"device-{m.group(1)}").read_text().strip()[:90]
                print(f"waiting {waited}s for simulator {m.group(1)[:8]}…; "
                      f"held by: {holder}", file=sys.stderr)
            time.sleep(1)
            waited += 1


def take():
    """Blocks until a slot is free, saying who holds them while it waits."""
    DIR.mkdir(exist_ok=True)
    waited = 0
    while True:
        for n in range(SLOTS):
            # opened for update rather than truncated: "w" would empty the file
            # before the lock is even attempted, wiping the holder that is still
            # in there
            handle = (DIR / f"slot{n}").open("a+")
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                handle.close()
                continue
            handle.seek(0)
            handle.truncate()
            handle.write(f"{os.getpid()} {' '.join(sys.argv[1:])[:200]}\n")
            handle.flush()
            return handle
        if waited % REPORT_EVERY == 0:
            held = " | ".join(
                (DIR / f"slot{n}").read_text().strip()[:90] for n in range(SLOTS)
                if (DIR / f"slot{n}").exists())
            print(f"waiting {waited}s for a build slot; held by: {held}", file=sys.stderr)
        time.sleep(1)
        waited += 1


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    # the device first: a slot held while waiting for a busy simulator would
    # starve the builds that could actually run
    device = take_device(sys.argv[1:])
    handle = take()
    try:
        return subprocess.run(sys.argv[1:]).returncode
    finally:
        handle.close()
        if device:
            device.close()


if __name__ == "__main__":
    sys.exit(main())
