#!/bin/bash
# Runs the server smoke against a stand of its own: a fresh D1 and DO state in a
# temporary directory, on a free port, torn down afterwards.
#
# The smoke asserts exact counts ("the backlog is 210 messages"), so it only
# holds on a database nobody has written to before. The shared stand on :8787
# carries the test users and conversations of every run before this one, and its
# leftovers read as failures here. It also cannot be shared: two `wrangler dev`
# processes over one state directory hand each other internal errors from
# Durable Object storage.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/msngr-smoke-XXXXXX")"

# A port is taken by making its lock directory (mkdir is atomic), not by
# looking at lsof: the push receiver is bound by node only once the smoke
# starts, so two of these scripts starting within the same minute both saw
# 9880 free and both stands then pushed into one receiver. The lock lives
# under a fixed path so every agent's copy of this script sees it, whatever
# its TMPDIR is, and goes with the run.
LOCKS=/tmp/msngr-smoke-ports
mkdir -p "$LOCKS"
free_port() {
  local p
  for p in $(seq "$1" "$(($1 + 40))"); do
    lsof -ti ":$p" >/dev/null 2>&1 && continue
    mkdir "$LOCKS/$p" 2>/dev/null || continue
    echo "$p"
    return
  done
  echo "no free port from $1" >&2
  exit 1
}

cleanup() {
  [ -n "${STAND_PID:-}" ] && kill "$STAND_PID" 2>/dev/null
  rm -rf "$STATE"
  [ -n "${PORT:-}" ] && rmdir "$LOCKS/$PORT" 2>/dev/null
  [ -n "${PUSH:-}" ] && rmdir "$LOCKS/$PUSH" 2>/dev/null
}
trap cleanup EXIT

PORT="$(free_port 8870)"
PUSH="$(free_port 9880)"

cd "$ROOT/server"
npx wrangler d1 migrations apply DB --local --persist-to "$STATE" >/dev/null
npx wrangler dev --port "$PORT" --persist-to "$STATE" \
  --var "APNS_HOST:http://localhost:$PUSH" \
  --var "CMID_MIN_AGE:0" --var "CMID_SWEEP_EVERY:0" > "$STATE/stand.log" 2>&1 &
STAND_PID=$!

for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://localhost:$PORT/api/me")" != "000" ] && break
  sleep 1
done

echo "smoke stand on :$PORT (push :$PUSH), state in $STATE"
RC=0
BASE_URL="http://localhost:$PORT" PUSH_PORT="$PUSH" node test/smoke.mjs || RC=$?
if [ "$RC" -ne 0 ]; then
  # the stand goes with the temporary directory, so what it logged is the one
  # trace of a red run: its warnings and errors go into the gate log with the
  # smoke's own output
  echo "--- stand log, warnings and errors:"
  sed 's/\x1b\[[0-9;]*m//g' "$STATE/stand.log" | grep -E "WARNING|ERROR|fanout:" | tail -n 120
fi
exit "$RC"
