#!/bin/bash
# Reclaims what dead agents leave behind. Safe to run at any time, including
# while agents are working — every rule below only touches things nothing can
# still be using.
#
#   scripts/tidy.sh          what would be removed
#   scripts/tidy.sh --apply  remove it
#
# Agents clean up after themselves when they finish. When one is killed — a
# session limit, a lost connection, a machine asleep — it leaves a simulator of
# about two gigabytes, a worktree, and a derived-data directory near a gigabyte.
# A day of that fills the disk.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=""
[ "${1:-}" = "--apply" ] && APPLY=1

# The owner's two devices and the gate runner are never touched.
KEEP="44CE2242-EBB9-48EA-A605-5988A00E4C31|0E0CF155-B4B7-4794-A963-AD7C76EFDCEA|74B78AFC-E8D7-4317-B16F-E51A65504B2D"

say() { [ -n "$APPLY" ] && echo "removed: $1" || echo "would remove: $1"; }
freed=0

# 1. Simulators that are shut down and were last written to over two hours ago.
#    A working agent keeps its simulator booted, so this cannot catch a live one.
while read -r name udid; do
  [ -z "$udid" ] && continue
  dev="$HOME/Library/Developer/CoreSimulator/Devices/$udid"
  [ -d "$dev" ] || continue
  age_h=$(( ( $(date +%s) - $(stat -f %m "$dev") ) / 3600 ))
  [ "$age_h" -lt 2 ] && continue
  size=$(du -sm "$dev" 2>/dev/null | cut -f1); freed=$((freed + size))
  say "simulator $name (${size}MB, idle ${age_h}h)"
  [ -n "$APPLY" ] && xcrun simctl delete "$udid" >/dev/null 2>&1
done < <(xcrun simctl list devices 2>/dev/null |
         grep "(Shutdown)" | grep -vE "$KEEP" |
         sed -E 's/^ *(.*) \(([0-9A-F-]{36})\).*/\1 \2/' |
         grep -viE "^(iPhone|iPad|Apple) ")

# 2. Worktrees whose branch is fully merged into main — the work is in main,
#    the directory is a copy of it.
for wt in "$ROOT"/.claude/worktrees/*/; do
  [ -d "$wt" ] || continue
  name="$(basename "$wt")"
  branch="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null |
            grep -A2 "^worktree $wt\?$" | grep '^branch' | sed 's|.*/||')"
  [ -z "$branch" ] && continue
  git -C "$ROOT" branch --merged main 2>/dev/null | tr -d ' *' | grep -qx "$branch" || continue
  size=$(du -sm "$wt" 2>/dev/null | cut -f1); freed=$((freed + size))
  say "worktree $name (${size}MB, branch merged)"
  [ -n "$APPLY" ] && { git -C "$ROOT" worktree remove "$wt" --force >/dev/null 2>&1 || rm -rf "$wt"; }
done
[ -n "$APPLY" ] && git -C "$ROOT" worktree prune

# 3. Derived data pointing at a workspace that no longer exists.
for d in "$HOME/Library/Developer/Xcode/DerivedData"/*/; do
  [ -f "$d/info.plist" ] || continue
  wp="$(grep -A1 WorkspacePath "$d/info.plist" 2>/dev/null | tail -1 | sed 's|.*<string>||;s|</string>||')"
  [ -n "$wp" ] && [ ! -e "$wp" ] || continue
  size=$(du -sm "$d" 2>/dev/null | cut -f1); freed=$((freed + size))
  say "derived data $(basename "$d") (${size}MB, workspace gone)"
  [ -n "$APPLY" ] && rm -rf "$d"
done

echo "---"
df -h / | tail -1
[ "$freed" -gt 0 ] && echo "$([ -n "$APPLY" ] && echo reclaimed || echo reclaimable): ${freed}MB"
exit 0
