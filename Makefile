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

.PHONY: check uicheck gen build unit layout uitest server-smoke crashes

check: gen build unit layout server-smoke crashes
	@echo "== make check: all green =="

# The UI smoke lives outside the gate: its reds have almost always been the
# host (a stale database on a shared device, a starved runner, a missing
# fixture user), not the code. Run it when the change touches the UI layer,
# on your own simulator: make uicheck DEV_UDID=<yours>
uicheck: gen build uitest
	@echo "== make uicheck: all green =="

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

# Build and install on a physical iPhone with a free Apple ID (Personal Team).
# One-time on the phone: Developer Mode on, trust this Mac; in Xcode: Settings →
# Accounts → your Apple ID, copy the Team ID. Then:
#   make device TEAM=ABCDE12345 [SERVER=http://<mac-lan-ip>:8787]
# The communication-notifications entitlement is stripped: a personal team
# cannot sign it, and pushes need a paid account anyway.
DEVICE_APP := ios/build/device/Build/Products/Debug-iphoneos/Msngr.app
device:
	@test -n "$(TEAM)" || (echo "make device TEAM=<Team ID из Xcode → Settings → Accounts>"; exit 1)
	cd ios && MSNGR_DEVICE_SERVER="$(or $(SERVER),https://msngr.a-kuz.online)" xcodegen
	plutil -remove "com\.apple\.developer\.usernotifications\.communication" ios/Msngr/Msngr.entitlements || true
	$(SLOT) xcodebuild -project ios/Msngr.xcodeproj -scheme Msngr \
	  -destination 'generic/platform=iOS' -derivedDataPath ios/build/device \
	  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$(TEAM) build
	xcrun devicectl device install app --device "$$(xcrun devicectl list devices --hide-headers 2>/dev/null | awk '/iPhone/{print $$NF; exit}')" $(DEVICE_APP)
	cd ios && xcodegen

server-smoke:
	bash scripts/smoke-stand.sh

crashes:
	bash scripts/collect-crashes.sh --since 240
