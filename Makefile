APP_NAME     := Contour
BUNDLE_ID    := com.nahak.contour
CONFIG       ?= release
IDENTITY     ?= Contour Dev
ENTITLEMENTS := Contour.entitlements
INFO_PLIST   := Resources/Info.plist
ICON         := Resources/AppIcon.icns
BUILD_DIR    := build
APP          := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR  ?= /Applications

.PHONY: all build bundle sign run install icon verify clean

all: sign

## Compile the bare executable with SwiftPM.
build:
	swift build -c $(CONFIG)

## Assemble the .app bundle. SwiftPM only emits a plain binary; SwiftUI needs
## a real bundle (Info.plist, LSUIElement, bundle identifier) to run at all.
bundle: build
	@bin=$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME); \
	rm -rf "$(APP)"; \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"; \
	cp "$$bin" "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	cp "$(INFO_PLIST)" "$(APP)/Contents/Info.plist"; \
	cp "$(ICON)" "$(APP)/Contents/Resources/AppIcon.icns"; \
	echo "assembled $(APP)"

## Sign with a stable identity AND an explicitly pinned designated requirement.
##
## The DR is the part TCC keys its grants to. Left to itself, codesign pins a
## self-signed build to `cdhash H"..."` — the hash of that exact binary — so
## every rebuild looks like a different app and microphone permission resets.
## Pinning to the certificate instead keeps the grant across rebuilds.
##
## `make IDENTITY=- ...` signs ad-hoc instead, for anyone who would rather not
## make a certificate. Same entitlements, same hardened runtime, and the app
## runs identically — but the DR falls back to the cdhash, so the microphone
## grant dies on the next rebuild. Fine if you build once; painful if you are
## editing the code. Recover with:
##     tccutil reset Microphone com.nahak.contour
sign: bundle
ifeq ($(IDENTITY),-)
	@codesign --force --options runtime \
		--entitlements "$(ENTITLEMENTS)" \
		--sign - \
		"$(APP)" && \
	echo "signed ad-hoc; the microphone grant will reset on the next rebuild"
else
	@hash=$$(security find-identity -v -p codesigning \
		| grep '"$(IDENTITY)"' | head -1 | awk '{print $$2}'); \
	if [ -z "$$hash" ]; then \
		echo "error: no code-signing identity named \"$(IDENTITY)\" in the keychain"; \
		echo "see README: create a self-signed certificate with that name,"; \
		echo "or sign ad-hoc instead with: make IDENTITY=- run"; \
		exit 1; \
	fi; \
	codesign --force --options runtime \
		--entitlements "$(ENTITLEMENTS)" \
		--sign "$(IDENTITY)" \
		--timestamp=none \
		-r="designated => identifier \"$(BUNDLE_ID)\" and certificate leaf = H\"$$hash\"" \
		"$(APP)" && \
	echo "signed as \"$(IDENTITY)\", requirement pinned to certificate $$hash"
endif

run: sign
	-@killall $(APP_NAME) 2>/dev/null || true
	open "$(APP)"

## Copy the signed app to /Applications, where Finder, Launchpad and Spotlight
## find it. The signature and its pinned requirement travel with the bundle, so
## the microphone grant carries over.
##
## SIGTERM goes through NSApp.terminate and exits zero, which the watchdog does
## not respawn, so the installed copy is the one that starts and it repoints the
## watchdog at itself on launch. Not an Apple Event quit: that times out while
## one of the popover's menus is open.
install: sign
	-@killall $(APP_NAME) 2>/dev/null || true
	@for i in $$(seq 50); do pgrep -qx $(APP_NAME) || break; sleep 0.1; done
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	open "$(INSTALL_DIR)/$(APP_NAME).app"

## Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	@tmp=$$(mktemp -d); set -e; \
	swift scripts/make-icon.swift "$$tmp/icon.png"; \
	mkdir "$$tmp/AppIcon.iconset"; \
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s "$$tmp/icon.png" --out "$$tmp/AppIcon.iconset/icon_$${s}x$${s}.png" >/dev/null; \
		d=$$((s * 2)); \
		sips -z $$d $$d "$$tmp/icon.png" --out "$$tmp/AppIcon.iconset/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done; \
	iconutil -c icns "$$tmp/AppIcon.iconset" -o "$(ICON)"; \
	rm -rf "$$tmp"; \
	echo "wrote $(ICON)"

verify:
	@echo "=== signing authority ==="
	@codesign -dvv "$(APP)" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature)' || true
	@echo
	@echo "=== designated requirement (must NOT be a bare cdhash) ==="
	@codesign -d -r- "$(APP)" 2>&1 | grep designated || true
	@echo
	@echo "=== embedded entitlements ==="
	@codesign -d --entitlements - --xml "$(APP)" 2>/dev/null | plutil -convert xml1 -o - -
	@echo
	@echo "=== gatekeeper/validity ==="
	@codesign --verify --strict --verbose=2 "$(APP)" 2>&1 || true

clean:
	rm -rf .build $(BUILD_DIR)
