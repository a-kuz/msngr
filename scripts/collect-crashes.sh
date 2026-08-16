#!/bin/bash
# Collects fresh Msngr crash reports out of DiagnosticReports.
# Usage: collect-crashes.sh [--since <minutes>], defaulting to 120.
# Exits 1 when fresh crashes were found, which fails the gate, and 0 when clean.
set -euo pipefail
SINCE_MIN="${2:-120}"
[ "${1:-}" = "--since" ] || SINCE_MIN=120
DST="$(cd "$(dirname "$0")/.." && pwd)/docs/qa/crashes"
mkdir -p "$DST"
FOUND=0
while IFS= read -r f; do
  base="$(basename "$f")"
  if [ ! -f "$DST/$base" ]; then
    cp "$f" "$DST/$base"
    echo "CRASH: $base"
    # a one-line digest: exception type and termination
    python3 - "$f" <<'EOF' || true
import json, sys
lines = open(sys.argv[1]).read().split("\n", 1)
body = json.loads(lines[1])
exc = body.get("exception", {})
term = body.get("termination", {})
print(f"  exc: {exc.get('type')} {exc.get('signal','')} | term: {term.get('namespace','')} {term.get('details', term.get('indicator',''))}")
EOF
    FOUND=1
  fi
done < <(find ~/Library/Logs/DiagnosticReports -name 'Msngr*.ips' -mmin "-$SINCE_MIN" 2>/dev/null)
if [ "$FOUND" = 1 ]; then
  echo "Fresh crashes copied into docs/qa/crashes/. Work them out before committing."
  exit 1
fi
echo "No crashes."
