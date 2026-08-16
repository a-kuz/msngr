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
import subprocess
import sys
import time
from pathlib import Path

SLOTS = int(os.environ.get("MSNGR_BUILD_SLOTS") or 2)
DIR = Path.home() / ".msngr-build-slots"
REPORT_EVERY = 30


def take():
    """Blocks until a slot is free, saying who holds them while it waits."""
    DIR.mkdir(exist_ok=True)
    waited = 0
    while True:
        for n in range(SLOTS):
            handle = (DIR / f"slot{n}").open("w")
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                handle.close()
                continue
            handle.write(f"{os.getpid()} {' '.join(sys.argv[1:])[:200]}\n")
            handle.flush()
            return handle
        if waited % REPORT_EVERY == 0:
            print(f"waiting for a build slot ({SLOTS} in use), {waited}s", file=sys.stderr)
        time.sleep(1)
        waited += 1


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    handle = take()
    try:
        return subprocess.run(sys.argv[1:]).returncode
    finally:
        handle.close()


if __name__ == "__main__":
    sys.exit(main())
