#!/usr/bin/env python3
"""Progress over time: lines of code and what is left of the roadmap.

Walks the first-parent history of main, takes the last commit of every day,
and for each measures two things: lines in tracked source files (Swift and the
server's TypeScript/JS) and the roadmap markers (done / built-but-unwatched /
not built). Prints a table with a progress bar per day; `--json` prints one
JSON object per day instead, oldest first.
"""

import json
import os
import subprocess
import sys

# counts are repo-wide regardless of where the script is invoked from
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

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


def defects(sha):
    """Defect entries by section of docs/qa/defects.md: still open vs fixed."""
    text = run(["show", f"{sha}:docs/qa/defects.md"])
    open_part, _, closed_part = text.partition("## Closed")
    return {"defects_open": open_part.count("\n### "),
            "defects_fixed": closed_part.count("\n### ")}


def rows():
    result = []
    for day, sha in daily_commits():
        row = {"day": day, "code": code_lines(sha), **roadmap(sha), **defects(sha)}
        row["left"] = row["unwatched"] + row["missing"]
        result.append(row)
    return result


def paint(text, color, enabled):
    if not enabled:
        return text
    codes = {"green": 32, "yellow": 33, "dim": 2, "bold": 1}
    return f"\033[{codes[color]}m{text}\033[0m"


def bar(done, unwatched, total, colored):
    """The roadmap as one strip against today's full item count, as if every
    item existed from day one: solid for done, half-tone for built but never
    watched live, dots for everything else — so the strip only ever grows."""
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
    print(paint(f"{'   ':<12}{'code':>7}{'':9}  {'✅':>3} {'🟡':>2} {'⬜':>2} "
                f"{'🐞':>2} {'✔':>3}   ",
                "bold", colored))
    total = max(r["done"] + r["unwatched"] + r["missing"] for r in data)
    prev = None
    for r in data:
        code_d = delta(r["code"], prev and prev["code"])
        done_d = delta(r["done"], prev and prev["done"])
        fixed_d = delta(r["defects_fixed"], prev and prev["defects_fixed"], "✔")
        line = (f"{r['day']:<12}{r['code']:>7}{code_d:<9}  "
                f"{r['done']:>4} {r['unwatched']:>3} {r['missing']:>3} "
                f"{r['defects_open']:>3} {r['defects_fixed']:>3}   "
                f"{bar(r['done'], r['unwatched'], total, colored)}"
                f"{paint(done_d, 'green', colored)}"
                f"{paint(fixed_d, 'green', colored)}")
        print(line)
        prev = r
    last = data[-1]
    pct = 100 * last["done"] // total if total else 0
    print()
    print(paint(f"🚀 {last['done']}/{total} ({pct}%)"
                f"    🐞 {last['defects_open']} open, {last['defects_fixed']} fixed",
                "dim", colored))


def tasks_in_work():
    """Lines of .claude/tasks.tsv: (agent, started, task, registered) — an
    agent registers its current task there and takes the line out on delivery.
    `registered` says whether the agent is also in .claude/agents.tsv."""
    agents = set()
    try:
        with open(".claude/agents.tsv") as fh:
            agents = {line.split("\t")[0] for line in fh if line.strip()}
    except OSError:
        pass
    result = []
    try:
        with open(".claude/tasks.tsv") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    result.append((parts[0], parts[1], parts[2], parts[0] in agents))
    except OSError:
        pass
    return result


def print_tasks(colored):
    tasks = tasks_in_work()
    if not tasks:
        return
    print()
    print(paint("in work now", "bold", colored))
    for agent, started, task, registered in tasks:
        mark = "" if registered else paint("  (agent not in agents.tsv)", "yellow", colored)
        print(f"  {agent:<10} {started:<17} {task}{mark}")


def main():
    data = rows()
    if not data:
        return 1
    if "--json" in sys.argv[1:]:
        for row in data:
            print(json.dumps(row))
    else:
        table(data)
        print_tasks(sys.stdout.isatty())


if __name__ == "__main__":
    sys.exit(main())
