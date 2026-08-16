#!/bin/bash
# Runs an implementation agent as its own process, with a session id we own.
#
# The Agent tool keeps part of a subagent's transcript location in memory, so a
# crashed agent can become unresumable while its file sits on disk. Here the id
# is ours: the transcript is always at
# ~/.claude/projects/<encoded-cwd>/<id>.jsonl and `claude -r <id>` picks it up.
# A stall watchdog does not apply either — this is a plain background process.
#
#   scripts/agent-run.sh start <name> <prompt-file> [worktree-branch]
#   scripts/agent-run.sh resume <name> <prompt>
#   scripts/agent-run.sh status [name]
#   scripts/agent-run.sh tail <name>
#
# State lives in .claude/agent-runs/<name>/ : id, log, worktree, status.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="$ROOT/.claude/agent-runs"
MODE="${1:-status}"

runner() {
  local name="$1" dir="$RUNS/$1" prompt="$2" cwd="$3" resume="${4:-}"
  local id; id="$(cat "$dir/id")"
  {
    if [ -n "$resume" ]; then
      claude -r "$id" -p --permission-mode bypassPermissions "$prompt" < /dev/null
    else
      claude -p --session-id "$id" --permission-mode bypassPermissions "$prompt" < /dev/null
    fi
    echo "$?" > "$dir/exit"
  } >> "$dir/log" 2>&1
  echo "finished" > "$dir/status"
}

case "$MODE" in
  start)
    name="${2:?name}"; prompt_file="${3:?prompt file}"; branch="${4:-}"
    dir="$RUNS/$name"; mkdir -p "$dir"
    [ -f "$dir/status" ] && [ "$(cat "$dir/status")" = "running" ] && {
      echo "already running: $name"; exit 1; }
    python3 -c "import uuid;print(uuid.uuid4())" > "$dir/id"
    cwd="$ROOT"
    if [ -n "$branch" ]; then
      cwd="$ROOT/.claude/worktrees/$branch"
      git -C "$ROOT" worktree add -b "$branch" "$cwd" HEAD >> "$dir/log" 2>&1 ||
        git -C "$ROOT" worktree add "$cwd" "$branch" >> "$dir/log" 2>&1
    fi
    echo "$cwd" > "$dir/worktree"
    echo "running" > "$dir/status"
    ( cd "$cwd" && runner "$name" "$(cat "$prompt_file")" "$cwd" ) &
    echo "started $name  id=$(cat "$dir/id")  cwd=$cwd"
    ;;

  resume)
    name="${2:?name}"; prompt="${3:?prompt}"
    dir="$RUNS/$name"; [ -d "$dir" ] || { echo "unknown: $name"; exit 1; }
    cwd="$(cat "$dir/worktree")"
    echo "running" > "$dir/status"
    ( cd "$cwd" && runner "$name" "$prompt" "$cwd" resume ) &
    echo "resumed $name  id=$(cat "$dir/id")"
    ;;

  status)
    [ -d "$RUNS" ] || { echo "no runs"; exit 0; }
    for dir in "$RUNS"/*/; do
      [ -d "$dir" ] || continue
      n="$(basename "$dir")"
      printf "%-22s %-9s %6s lines  %s\n" "$n" \
        "$(cat "$dir/status" 2>/dev/null || echo '?')" \
        "$(wc -l < "$dir/log" 2>/dev/null | tr -d ' ')" \
        "$(cat "$dir/id" 2>/dev/null)"
    done
    ;;

  tail)
    name="${2:?name}"; tail -40 "$RUNS/$name/log"
    ;;

  *)
    echo "usage: agent-run.sh {start|resume|status|tail}"; exit 1
    ;;
esac
