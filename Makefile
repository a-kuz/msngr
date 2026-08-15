# Гейт качества: make check — перед каждым коммитом.
DEV_UDID := 44CE2242-EBB9-48EA-A605-5988A00E4C31
DEST := -destination 'id=$(DEV_UDID)'
XCODE := xcodebuild -project ios/Msngr.xcodeproj
# для агента на своём стенде: make check MSNGR_SERVER=http://localhost:8809 PUSH_PORT=9873
MSNGR_SERVER := http://localhost:8787
PUSH_PORT := 9871

.PHONY: check gen build unit layout uitest server-smoke crashes

check: gen build unit layout uitest server-smoke crashes
	@echo "== make check: всё зелёное =="

gen:
	cd ios && xcodegen

build:
	$(XCODE) -scheme Msngr $(DEST) -configuration Debug build 2>&1 | tail -2 | grep -q "BUILD SUCCEEDED"

unit:
	cd ios/MsngrKit && swift test 2>&1 | tail -3 | grep -q "passed"

layout:
	$(XCODE) -scheme Msngr $(DEST) test -only-testing:MsngrTests 2>&1 | tail -5 | grep -q "TEST SUCCEEDED"

uitest:
	@test "$$(curl -s -o /dev/null -w '%{http_code}' -m 3 $(MSNGR_SERVER)/api/me)" != "000" || (echo "wrangler dev не запущен ($(MSNGR_SERVER)): npx wrangler dev"; exit 1)
	MSNGR_SERVER=$(MSNGR_SERVER) $(XCODE) -scheme Msngr $(DEST) test -only-testing:MsngrUITests 2>&1 | tail -5 | grep -q "TEST SUCCEEDED"

server-smoke:
	cd server && BASE_URL=$(MSNGR_SERVER) PUSH_PORT=$(PUSH_PORT) node test/smoke.mjs

crashes:
	bash scripts/collect-crashes.sh --since 240
