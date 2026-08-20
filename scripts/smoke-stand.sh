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

free_port() {
  local p
  for p in $(seq "$1" "$(($1 + 40))"); do
    lsof -ti ":$p" >/dev/null 2>&1 || { echo "$p"; return; }
  done
  echo "no free port from $1" >&2
  exit 1
}

PORT="$(free_port 8870)"
PUSH="$(free_port 9880)"

cleanup() {
  [ -n "${STAND_PID:-}" ] && kill "$STAND_PID" 2>/dev/null
  rm -rf "$STATE"
}
trap cleanup EXIT

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
BASE_URL="http://localhost:$PORT" PUSH_PORT="$PUSH" node test/smoke.mjs
