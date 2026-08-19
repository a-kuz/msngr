#!/usr/bin/env python3
"""Progress over time: lines of code and what is left of the roadmap.

Walks the first-parent history of main, takes the last commit of every day,
and for each measures two things: lines in tracked source files (Swift and the
server's TypeScript/JS) and the roadmap markers (done / built-but-unwatched /
not built). Prints one JSON object per day, oldest first.
"""

import json
import subprocess
import sys

SOURCES = ["*.swift", "*.ts", "*.mjs"]


def run(args):
    return subprocess.run(["git"] + args, capture_output=True, text=True).stdout


def daily_commits():
    """The last first-parent commit of each day on main."""
    out = run(["log", "--first-parent", "--format=%H %cI", "main"])
    days = {}
    for line in out.splitlines():
        sha, stamp = line.split()
        days.setdefault(stamp[:10], sha)  # log is newest-first: first seen wins
    return sorted(days.items())


def code_lines(sha):
    out = run(["grep", "-c", "", sha, "--"] + SOURCES)
    return sum(int(line.rsplit(":", 1)[1]) for line in out.splitlines() if ":" in line)


def roadmap(sha):
    text = run(["show", f"{sha}:ROADMAP.md"])
    return {"done": text.count("✅"), "unwatched": text.count("🟡"),
            "missing": text.count("⬜")}


def main():
    for day, sha in daily_commits():
        row = {"day": day, "code": code_lines(sha), **roadmap(sha)}
        row["left"] = row["unwatched"] + row["missing"]
        print(json.dumps(row))


if __name__ == "__main__":
    sys.exit(main())
