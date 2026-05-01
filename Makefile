# sift Makefile — build the CLI, build + bundle the menu bar app,
# codesign with an ad-hoc identity, install both into the user's
# ~/.local/bin and /Applications.

PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
APPDIR ?= /Applications
APP_NAME := Sift
APP_PRODUCT := sift-menubar  # SPM product name (lowercased to dodge case-insensitive FS clash with `sift`)
BUNDLE_ID := eco.datadesk.sift.menubar
BUILD_CONFIG ?= release

# Pulled from Sift.version so there's a single source of truth — the
# Info.plist below interpolates this, and `make release` zips a file
# named Sift-vX.Y.Z.zip. Override on the command line for testing.
VERSION ?= $(shell awk -F'"' '/public static let version/ {print $$2; exit}' Sources/SiftCore/SiftCore.swift)

BUILD_DIR := .build/$(BUILD_CONFIG)
APP_BUNDLE := $(APP_NAME).app
RELEASE_DIR := .build/release-bundle
RELEASE_ZIP := $(RELEASE_DIR)/$(APP_NAME)-v$(VERSION).zip

# Sift-owned tooling lives here so we don't pollute npm globals and
# uninstalling sift cleans up after itself.
SUPPORT_DIR := $(HOME)/Library/Application Support/Sift
PI_DIR := $(SUPPORT_DIR)/pi
PI_PACKAGE := @mariozechner/pi-coding-agent

.PHONY: all build cli app bundle codesign install install-cli install-app install-pi uninstall run clean release release-bundle release-codesign release-zip print-version

all: build

build: cli app

cli:
	swift build -c $(BUILD_CONFIG) --product sift

app: bundle codesign

bundle: cli-menubar
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_PRODUCT) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@printf '%s\n' "$$INFO_PLIST" > $(APP_BUNDLE)/Contents/Info.plist
	@printf '%s' "APPL????" > $(APP_BUNDLE)/Contents/PkgInfo
	@echo "bundled  -> $(APP_BUNDLE)"

cli-menubar:
	swift build -c $(BUILD_CONFIG) --product $(APP_PRODUCT)

codesign: bundle
	@codesign --force --deep --sign - \
		--options runtime \
		--entitlements Sift.entitlements \
		$(APP_BUNDLE) 2>/dev/null \
		|| codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "signed   -> $(APP_BUNDLE) (ad-hoc)"

install: install-cli install-app install-pi
	@echo "done. add $(BINDIR) to PATH if it isn't already."

install-pi:
	@command -v npm >/dev/null 2>&1 || { \
		echo "npm not found — install Node first ('brew install node')." >&2; \
		exit 1; \
	}
	@mkdir -p "$(PI_DIR)"
	@echo "pi       -> installing $(PI_PACKAGE) into $(PI_DIR)"
	@cd "$(PI_DIR)" && npm install --silent --no-audit --no-fund \
		--prefix "$(PI_DIR)" $(PI_PACKAGE)
	@echo "pi       -> $(PI_DIR)/node_modules/.bin/pi"

uninstall:
	@rm -f $(BINDIR)/sift
	@rm -rf $(APPDIR)/$(APP_BUNDLE)
	@rm -rf "$(SUPPORT_DIR)"
	@echo "uninstalled. ~/.sift (vault, models, sessions) is untouched — remove it manually if you're done with sift."

install-cli: cli
	@mkdir -p $(BINDIR)
	@install -m 0755 $(BUILD_DIR)/sift $(BINDIR)/sift
	@echo "cli      -> $(BINDIR)/sift"

install-app: app
	@# Quit any running copy first so the freshly installed binary is
	@# the one macOS launches; otherwise the old process keeps running
	@# and the user sees stale behaviour after `make install`.
	@osascript -e 'tell application id "eco.datadesk.sift.menubar" to quit' 2>/dev/null || true
	@pkill -f "$(APPDIR)/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@rm -rf $(APPDIR)/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) $(APPDIR)/$(APP_BUNDLE)
	@echo "app      -> $(APPDIR)/$(APP_BUNDLE)"
	@open -ga "$(APPDIR)/$(APP_BUNDLE)"
	@echo "app      -> launched (menu bar)"

run: install-cli
	$(BINDIR)/sift --help

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(RELEASE_DIR)

print-version:
	@echo $(VERSION)

# `make release` produces a self-contained Sift.app at $(RELEASE_DIR)/Sift.app
# with the CLI binary and the pi npm package both bundled inside, then
# zips it for upload to a GitHub Release. The Homebrew cask points at
# the resulting URL/SHA256.
release: release-zip
	@echo "release  -> $(RELEASE_ZIP)"
	@echo "sha256   -> $$(/usr/bin/shasum -a 256 $(RELEASE_ZIP) | awk '{print $$1}')"

release-bundle: cli cli-menubar
	@command -v npm >/dev/null 2>&1 || { \
		echo "npm not found — install Node first ('brew install node')." >&2; \
		exit 1; \
	}
	@rm -rf $(RELEASE_DIR)
	@mkdir -p $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/bin
	@mkdir -p $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/pi
	@cp $(BUILD_DIR)/$(APP_PRODUCT) $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(BUILD_DIR)/sift $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/bin/sift
	@# SPM emits the resource bundle next to the binary; ship it next
	@# to the CLI inside the .app so Bundle.module still resolves.
	@if [ -d $(BUILD_DIR)/sift_SiftCLI.bundle ]; then \
		cp -R $(BUILD_DIR)/sift_SiftCLI.bundle $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/bin/; \
	fi
	@printf '%s\n' "$$INFO_PLIST" > $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Info.plist
	@printf '%s' "APPL????" > $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/PkgInfo
	@echo "pi       -> bundling $(PI_PACKAGE) into $(APP_BUNDLE)"
	@cd $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/pi && \
		npm install --silent --no-audit --no-fund \
		--prefix . $(PI_PACKAGE)
	@echo "bundled  -> $(RELEASE_DIR)/$(APP_BUNDLE) (v$(VERSION))"

release-codesign: release-bundle
	@codesign --force --deep --sign - \
		--options runtime \
		--entitlements Sift.entitlements \
		$(RELEASE_DIR)/$(APP_BUNDLE) 2>/dev/null \
		|| codesign --force --deep --sign - $(RELEASE_DIR)/$(APP_BUNDLE)
	@echo "signed   -> $(RELEASE_DIR)/$(APP_BUNDLE) (ad-hoc, deep)"

release-zip: release-codesign
	@cd $(RELEASE_DIR) && /usr/bin/ditto -c -k --keepParent $(APP_BUNDLE) $(APP_NAME)-v$(VERSION).zip

# Embedded Info.plist — kept inline so there's no separate file to
# get out of sync. LSUIElement=1 makes this a menu-bar-only app
# (no Dock icon, no app switcher entry).
define INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>            <string>Sift</string>
  <key>CFBundleExecutable</key>             <string>Sift</string>
  <key>CFBundleIconFile</key>               <string></string>
  <key>CFBundleIdentifier</key>             <string>$(BUNDLE_ID)</string>
  <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
  <key>CFBundleName</key>                   <string>Sift</string>
  <key>CFBundlePackageType</key>            <string>APPL</string>
  <key>CFBundleShortVersionString</key>     <string>$(VERSION)</string>
  <key>CFBundleVersion</key>                <string>$(VERSION)</string>
  <key>LSMinimumSystemVersion</key>         <string>14.0</string>
  <key>LSUIElement</key>                    <true/>
  <key>NSHumanReadableCopyright</key>       <string>MIT licensed.</string>
  <key>NSSupportsAutomaticTermination</key> <true/>
  <key>NSSupportsSuddenTermination</key>    <true/>
</dict>
</plist>
endef
export INFO_PLIST
