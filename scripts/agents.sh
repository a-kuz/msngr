#!/bin/bash
# What every running agent is doing. Reads only; starting and steering agents is
# done by hand with `claude -p --session-id …` and `claude -r …`.
#
# Registry is one line per agent in .claude/agents.tsv:  name<TAB>sessionId<TAB>worktree
#
# A process in `ps` means alive. No process means finished or killed.
#
# Stuck is: the process exists, its last tool call was not a shell command, and
# nothing has been written to the transcript for 90 seconds. A shell command can
# legitimately take minutes — a build, a test run, a simulator boot — so waiting
# on one is not a stall. Nothing else takes that long.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/.claude/agents.tsv"
PROJ="$HOME/.claude/projects"
[ -f "$REG" ] || { echo "no agents registered"; exit 0; }

printf "%-10s %-9s %-6s %-10s %-7s %s\n" NAME STATE IDLE TOOL COMMITS LAST
while IFS=$'\t' read -r name sid wt; do
  [ -z "${name:-}" ] && continue
  pid="$(pgrep -f "$sid" | head -1)"
  jsonl="$(find "$PROJ" -name "$sid.jsonl" 2>/dev/null | head -1)"
  idle="-"
  [ -n "$jsonl" ] && idle="$(python3 -c "import os,time;print(int(time.time()-os.path.getmtime('$jsonl')))")"

  tool="-"
  [ -n "$jsonl" ] && tool="$(tail -60 "$jsonl" | python3 -c "
import sys, json
last = '-'
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    c = d.get('message', {}).get('content')
    if isinstance(c, list):
        for b in c:
            if b.get('type') == 'tool_use':
                last = b.get('name', '?')
print(last)
" 2>/dev/null)"

  if [ -z "$pid" ]; then state="done"
  elif [ "$tool" != "Bash" ] && [ "$idle" != "-" ] && [ "$idle" -gt 90 ]; then state="STUCK"
  else state="running"; fi

  # the worktree names itself; its branch may be named after the task instead
  branch="$(git -C "$ROOT/.claude/worktrees/$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  commits="$(git -C "$ROOT" log --oneline "main..${branch:-$wt}" 2>/dev/null | wc -l | tr -d ' ')"
  last="$(git -C "$ROOT" log -1 --format=%s "${branch:-$wt}" 2>/dev/null | cut -c1-46)"
  printf "%-10s %-9s %-6s %-10s %-7s %s\n" "$name" "$state" "${idle}s" "$tool" "$commits" "$last"
done < "$REG"
