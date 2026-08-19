#!/bin/bash
# Collects fresh Msngr crash reports out of DiagnosticReports.
# Usage: collect-crashes.sh [--since <minutes>], defaulting to 120.
# Exits 1 when a fresh crash of ours was found, which fails the gate, and 0 when
# clean. A launch failure of the XCTest harness (bundle id ending in .xctrunner)
# is printed and does not fail the gate: our binary never ran in it, and what it
# reports is the state of the runner bundle on that simulator.
set -euo pipefail
SINCE_MIN="${2:-120}"
[ "${1:-}" = "--since" ] || SINCE_MIN=120
DST="$(cd "$(dirname "$0")/.." && pwd)/docs/qa/crashes"
mkdir -p "$DST"
FOUND=0
while IFS= read -r f; do
  base="$(basename "$f")"
  [ -f "$DST/$base" ] && continue
  # classify first: only ours is copied into the repository
  if python3 - "$f" <<'EOF'
import json, sys
text = open(sys.argv[1]).read().split("\n", 1)
head, body = json.loads(text[0]), json.loads(text[1])
exc = body.get("exception", {})
term = body.get("termination", {})
harness = str(head.get("bundleID", "")).endswith(".xctrunner")
kind = "HARNESS" if harness else "CRASH"
print(f"{kind}: {head.get('name')} {head.get('timestamp')}")
print(f"  exc: {exc.get('type')} {exc.get('signal','')} | term: {term.get('namespace','')} {term.get('details', term.get('indicator',''))}")
if reasons := term.get("reasons"):
    print(f"  {reasons[0]}")
sys.exit(1 if harness else 0)
EOF
  then
    cp "$f" "$DST/$base"
    FOUND=1
  fi
done < <(find ~/Library/Logs/DiagnosticReports -name 'Msngr*.ips' -mmin "-$SINCE_MIN" 2>/dev/null)
if [ "$FOUND" = 1 ]; then
  echo "Fresh crashes copied into docs/qa/crashes/. Work them out before committing."
  exit 1
fi
echo "No crashes of ours."
