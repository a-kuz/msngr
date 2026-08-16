# The quality gate: run make check before every commit.
DEV_UDID := 44CE2242-EBB9-48EA-A605-5988A00E4C31
DEST := -destination 'id=$(DEV_UDID)'
# every agent builds the same project on the same host, so builds queue for a
# shared slot instead of running all at once (scripts/build-slot.py)
SLOT := python3 scripts/build-slot.py
XCODE := $(SLOT) xcodebuild -project ios/Msngr.xcodeproj
# The UI tests need the shared stand and the fixtures on it; the server smoke
# raises a clean stand of its own (scripts/smoke-stand.sh).
# for an agent on its own stand: make check MSNGR_SERVER=http://localhost:8809
MSNGR_SERVER := http://localhost:8787

.PHONY: check gen build unit layout uitest server-smoke crashes

check: gen build unit layout uitest server-smoke crashes
	@echo "== make check: all green =="

gen:
	cd ios && xcodegen

build:
	$(XCODE) -scheme Msngr $(DEST) -configuration Debug build 2>&1 | tail -2 | grep -q "BUILD SUCCEEDED"

unit:
	cd ios/MsngrKit && $(CURDIR)/scripts/build-slot.py swift test 2>&1 | tail -3 | grep -q "passed"

layout:
	$(XCODE) -scheme Msngr $(DEST) test -only-testing:MsngrTests 2>&1 | tail -5 | grep -q "TEST SUCCEEDED"

uitest:
	@test "$$(curl -s -o /dev/null -w '%{http_code}' -m 3 $(MSNGR_SERVER)/api/me)" != "000" || (echo "wrangler dev is not running ($(MSNGR_SERVER)): npx wrangler dev"; exit 1)
	MSNGR_SERVER=$(MSNGR_SERVER) $(XCODE) -scheme Msngr $(DEST) test -only-testing:MsngrUITests 2>&1 | tail -5 | grep -q "TEST SUCCEEDED"

server-smoke:
	bash scripts/smoke-stand.sh

crashes:
	bash scripts/collect-crashes.sh --since 240
