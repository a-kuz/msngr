#!/usr/bin/env python3
"""What every running agent is doing, at a glance.

Registry is one line per agent in .claude/agents.tsv: name<TAB>sessionId<TAB>worktree.
Starting and steering agents is done by hand with `claude -p --session-id …` and
`claude -r …`; this only reads.

A process in `ps` means alive. Stuck is: the process exists, its last tool call was
not a shell command, and nothing has been written to the transcript for 90 seconds.
A shell command can legitimately take minutes — a build, a test run, a simulator
boot — so waiting on one is not a stall. Nothing else takes that long.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

def repo_root():
    """The main working tree, wherever this copy of the script lives.

    Agents run in worktrees, and each worktree carries its own copy of this file.
    The registry lives in the main tree only, so a copy that trusts `__file__`
    answers "no agents registered" from inside a worktree — which reads as
    information and is a lie. Git knows where the common dir is; ask it.
    """
    here = Path(__file__).resolve().parent.parent
    try:
        common = subprocess.run(
            ["git", "-C", str(here), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=10).stdout.strip()
        if common:
            return Path(common).parent
    except (subprocess.SubprocessError, OSError):
        pass
    return here


ROOT = repo_root()
REGISTRY = ROOT / ".claude" / "agents.tsv"
PROJECTS = Path.home() / ".claude" / "projects"

# `watch` pipes us, and a pipe that gets escape codes shows them as text. Colour is
# for a terminal; `watch -c` asks for it back through CLICOLOR_FORCE.
COLOUR = sys.stdout.isatty() or os.environ.get("CLICOLOR_FORCE") == "1"
RESET, BOLD, DIM = ("\033[0m", "\033[1m", "\033[2m") if COLOUR else ("", "", "")
GREEN, YELLOW, GREY = ("\033[32m", "\033[33m", "\033[90m") if COLOUR else ("", "", "")

def terminal_width():
    try:
        return os.get_terminal_size().columns
    except OSError:
        return int(os.environ.get("COLUMNS") or 0) or 110


WIDTH = terminal_width()

# how much of a transcript's end is read on the first try
TAIL = 512 * 1024


def ago(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    return f"{seconds // 86400}d"


def one_line(text, limit=None):
    """One line that fits the terminal: `watch` clips anything wider without a hint."""
    limit = limit or WIDTH - 2
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def tool_call(name, args):
    """A tool call the way its author would read it back."""
    if not isinstance(args, dict):
        return name
    inner = WIDTH - len(name) - 6
    for key in ("command", "file_path", "pattern", "prompt", "query", "url"):
        if key in args:
            return f"{name}({one_line(args[key], inner)})"
    return f"{name}({one_line(json.dumps(args, ensure_ascii=False), inner)})"


def transcript(session_id):
    for path in PROJECTS.glob(f"*/{session_id}.jsonl"):
        return path
    return None


def entries(chunk):
    for line in chunk.splitlines():
        try:
            yield json.loads(line)
        except ValueError:
            continue


def read(path, tail=TAIL):
    """Start time, last words, last tool call.

    A transcript of a working day is hundreds of megabytes, and `watch` reruns this
    every couple of seconds: the start is at the head of the file and everything else
    is at its end, so only those two pieces are read. A tail that holds no assistant
    text yet is grown until it does or the file runs out.
    """
    size = path.stat().st_size
    with path.open(errors="replace") as f:
        head = f.read(64 * 1024)
        started = next((e["timestamp"] for e in entries(head) if e.get("timestamp")), None)
        last_text = last_tool = None
        while tail <= size:
            f.seek(max(0, size - tail))
            chunk = f.read()
            if tail < size:  # the first line of a mid-file seek is half a line
                chunk = chunk.split("\n", 1)[-1]
            for entry in entries(chunk):
                content = entry.get("message", {}).get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    kind = block.get("type")
                    if kind == "text" and entry.get("type") == "assistant":
                        text = block.get("text", "").strip()
                        if text:
                            last_text = text
                    elif kind == "tool_use":
                        last_tool = tool_call(block.get("name", "?"), block.get("input"))
            if last_text or tail >= size:
                break
            tail *= 8
    return started, last_text, last_tool


def started_ago(stamp):
    if not stamp:
        return "?"
    try:
        from datetime import datetime, timezone

        when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        return ago((datetime.now(timezone.utc) - when).total_seconds())
    except ValueError:
        return "?"


def running():
    """The whole process table at once: one `ps` beats a `pgrep` per agent."""
    return subprocess.run(["ps", "-Ao", "command"], capture_output=True, text=True).stdout


def main():
    if not REGISTRY.exists():
        print("no agents registered")
        return
    processes = running()
    for line in REGISTRY.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0].strip():
            continue
        name, session_id = parts[0], parts[1]
        worktree = parts[2] if len(parts) > 2 else ""

        alive = session_id in processes
        path = transcript(session_id)
        if path is None:
            print(f"{BOLD}{name}{RESET}  {GREY}no transcript for {session_id}{RESET}\n")
            continue

        idle = time.time() - path.stat().st_mtime
        start, text, tool = read(path)
        shell = bool(tool) and tool.startswith("Bash(")

        if not alive:
            state, colour = "done", GREY
        elif not shell and idle > 90:
            state, colour = "STUCK", YELLOW
        else:
            state, colour = "running", GREEN

        head = f"{BOLD}{name}{RESET} {colour}{state}{RESET}"
        print(f"{head}  {DIM}quiet {ago(idle)} · started {started_ago(start)} ago · {worktree}{RESET}")
        if text:
            print(f"  {one_line(text)}")
        if tool:
            print(f"  {DIM}{one_line(tool, WIDTH - 4)}{RESET}")
        print()


if __name__ == "__main__":
    sys.exit(main())
