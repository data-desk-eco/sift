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

BUILD_DIR := .build/$(BUILD_CONFIG)
APP_BUNDLE := $(APP_NAME).app

.PHONY: all build cli app bundle codesign install install-cli install-app run clean

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

install: install-cli install-app
	@echo "done. add $(BINDIR) to PATH if it isn't already."

install-cli: cli
	@mkdir -p $(BINDIR)
	@install -m 0755 $(BUILD_DIR)/sift $(BINDIR)/sift
	@echo "cli      -> $(BINDIR)/sift"

install-app: app
	@rm -rf $(APPDIR)/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) $(APPDIR)/$(APP_BUNDLE)
	@echo "app      -> $(APPDIR)/$(APP_BUNDLE)"

run: install-cli
	$(BINDIR)/sift --help

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

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
  <key>CFBundleShortVersionString</key>     <string>0.1.0</string>
  <key>CFBundleVersion</key>                <string>1</string>
  <key>LSMinimumSystemVersion</key>         <string>14.0</string>
  <key>LSUIElement</key>                    <true/>
  <key>NSAppleEventsUsageDescription</key>  <string>Sift uses Terminal to show live agent logs.</string>
  <key>NSHumanReadableCopyright</key>       <string>MIT licensed.</string>
  <key>NSSupportsAutomaticTermination</key> <true/>
  <key>NSSupportsSuddenTermination</key>    <true/>
</dict>
</plist>
endef
export INFO_PLIST
