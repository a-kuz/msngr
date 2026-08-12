#!/bin/bash
# Сбор свежих креш-репортов Msngr из DiagnosticReports.
# Использование: collect-crashes.sh [--since <minutes>] (по умолчанию 120)
# Выход: 1 если найдены свежие краши (гейт красный), 0 если чисто.
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
    # краткая выжимка: тип и termination
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
  echo "Свежие краши скопированы в docs/qa/crashes/ — разберите перед коммитом."
  exit 1
fi
echo "Крашей нет."
