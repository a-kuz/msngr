#!/usr/bin/env python3
"""Progress over time: lines of code and what is left of the roadmap.

Walks the first-parent history of main, takes the last commit of every day,
and for each measures two things: lines in tracked source files (Swift and the
server's TypeScript/JS) and the roadmap markers (done / built-but-unwatched /
not built). Prints a table with a progress bar per day; `--json` prints one
JSON object per day instead, oldest first.
"""

import json
import subprocess
import sys

SOURCES = ["*.swift", "*.ts", "*.mjs"]
BAR_WIDTH = 30


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


def rows():
    result = []
    for day, sha in daily_commits():
        row = {"day": day, "code": code_lines(sha), **roadmap(sha)}
        row["left"] = row["unwatched"] + row["missing"]
        result.append(row)
    return result


def paint(text, color, enabled):
    if not enabled:
        return text
    codes = {"green": 32, "yellow": 33, "dim": 2, "bold": 1}
    return f"\033[{codes[color]}m{text}\033[0m"


def bar(done, unwatched, missing, colored):
    """The roadmap as one strip: solid for done, half-tone for built but never
    watched live, dots for what does not exist yet."""
    total = done + unwatched + missing
    if not total:
        return " " * BAR_WIDTH
    d = round(BAR_WIDTH * done / total)
    u = round(BAR_WIDTH * unwatched / total)
    m = BAR_WIDTH - d - u
    return (paint("█" * d, "green", colored)
            + paint("▒" * u, "yellow", colored)
            + paint("·" * m, "dim", colored))


def delta(value, prev, unit=""):
    if prev is None or value == prev:
        return ""
    sign = "+" if value > prev else ""
    return f" ({sign}{value - prev}{unit})"


def table(data):
    colored = sys.stdout.isatty()
    print(paint(f"{'day':<12}{'code':>7}{'':9}  {'✅':>4} {'🟡':>3} {'⬜':>3}   roadmap",
                "bold", colored))
    prev = None
    for r in data:
        code_d = delta(r["code"], prev and prev["code"])
        done_d = delta(r["done"], prev and prev["done"])
        line = (f"{r['day']:<12}{r['code']:>7}{code_d:<9}  "
                f"{r['done']:>4} {r['unwatched']:>3} {r['missing']:>3}   "
                f"{bar(r['done'], r['unwatched'], r['missing'], colored)}"
                f"{paint(done_d, 'green', colored)}")
        print(line)
        prev = r
    last = data[-1]
    total = last["done"] + last["unwatched"] + last["missing"]
    pct = 100 * last["done"] // total if total else 0
    print(paint(f"{'':12}{'█ done':>10}   ▒ built, not watched   · not built"
                f"   — {last['done']}/{total} ({pct}%)", "dim", colored))


def main():
    data = rows()
    if not data:
        return 1
    if "--json" in sys.argv[1:]:
        for row in data:
            print(json.dumps(row))
    else:
        table(data)


if __name__ == "__main__":
    sys.exit(main())
