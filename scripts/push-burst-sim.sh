#!/bin/bash
# Delivers a burst of alerts to a simulator, shaped like the payload the server
# sends. Reproduces what a device gets after a long offline, minus the
# extension: `simctl push` never starts a Notification Service Extension
# (docs/research/nse-simulator-experiment.md), so what this measures is the
# system side — the order of the notification centre and how many entries it
# keeps.
#
# Usage: scripts/push-burst-sim.sh <udid> <count> [chatId] [tag]
set -e
UDID="$1"
COUNT="$2"
CHAT="${3:-burst-chat}"
TAG="${4:-burst}"
if [ -z "$UDID" ] || [ -z "$COUNT" ]; then
  echo "usage: $0 <udid> <count> [chatId] [tag]" >&2
  exit 2
fi
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
i=1
while [ "$i" -le "$COUNT" ]; do
  cat > "$DIR/p$i.json" <<JSON
{
  "aps": {
    "alert": { "title": "Msngr", "body": "$TAG $i" },
    "sound": "default",
    "mutable-content": 1,
    "thread-id": "$CHAT",
    "badge": $i
  },
  "chatId": "$CHAT",
  "msgId": "$TAG-$i",
  "seq": $i,
  "sentAt": $i
}
JSON
  i=$((i + 1))
done
i=1
while [ "$i" -le "$COUNT" ]; do
  xcrun simctl push "$UDID" ai.enface.Msngr "$DIR/p$i.json" > /dev/null
  i=$((i + 1))
done
echo "pushed $COUNT"
