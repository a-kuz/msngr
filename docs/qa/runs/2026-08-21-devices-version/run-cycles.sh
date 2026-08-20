#!/bin/bash
cd /Users/alexsandrkuznetsov/ws/msngr/.claude/worktrees/run-devices
A=C50D682B-429E-4E60-9056-732719906779
for i in $(seq 1 8); do
  base=$(grep -c UPGRADE run-proxy.log)
  echo "$(date -u +%T) cycle $i: dropping proxy (upgrades so far: $base)" >> run-cycles.log
  pkill -f "node run-proxy.mjs"
  sleep 4
  nohup node run-proxy.mjs >/dev/null 2>&1 &
  disown
  for t in $(seq 1 40); do
    n=$(grep -c UPGRADE run-proxy.log)
    [ $((n - base)) -ge 2 ] && break
    sleep 1
  done
  echo "$(date -u +%T) cycle $i: reconnected (upgrades total: $n)" >> run-cycles.log
  sleep 1
  idb ui tap --udid $A 250 800
  sleep 1
  idb ui text --udid $A "c $i"
  sleep 1
  idb ui tap --udid $A 357 795
  sleep 2
  echo "$(date -u +%T) cycle $i: sent" >> run-cycles.log
done
echo "$(date -u +%T) all cycles done" >> run-cycles.log
