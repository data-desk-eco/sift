# sift Makefile — build the CLI and install it (plus the pi agent
# harness) into the user's ~/.local/bin. The menu bar app is gone; sift
# is a CLI only. `make release` still emits a Sift.app the Homebrew cask
# installs, but the bundle just carries the CLI + pi (no GUI process).

PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
APP_NAME := Sift
BUILD_CONFIG ?= release
BUNDLE_ID := eco.datadesk.sift

# Pulled from Sift.version so there's a single source of truth — the
# Info.plist below interpolates this, and `make release` zips a file
# named Sift-vX.Y.Z.zip. Override on the command line for testing.
VERSION ?= $(shell awk -F'"' '/public static let version/ {print $$2; exit}' Sources/SiftCore/SiftCore.swift)

BUILD_DIR := .build/$(BUILD_CONFIG)
APP_BUNDLE := $(APP_NAME).app
RELEASE_DIR := .build/release-bundle

# Sift-owned tooling lives here so we don't pollute npm globals and
# uninstalling sift cleans up after itself.
SUPPORT_DIR := $(HOME)/Library/Application Support/Sift
PI_DIR := $(SUPPORT_DIR)/pi
PI_PACKAGE := @mariozechner/pi-coding-agent

.PHONY: all build cli install install-cli install-pi uninstall run clean release release-bundle release-codesign release-zip print-version test prune-pi

all: build

build: cli

cli:
	swift build -c $(BUILD_CONFIG) --product sift

install: install-cli install-pi
	@echo "done. add $(BINDIR) to PATH if it isn't already."

install-cli: cli
	@mkdir -p $(BINDIR)
	@install -m 0755 $(BUILD_DIR)/sift $(BINDIR)/sift
	@# SPM emits the resource bundle alongside the binary in .build/.
	@# `sift auto` discovers AGENTS.md / SKILL.md via executableDir +
	@# Sift_SiftCLI.bundle, so the bundle has to ride along with the CLI.
	@rm -rf $(BINDIR)/Sift_SiftCLI.bundle
	@cp -R $(BUILD_DIR)/Sift_SiftCLI.bundle $(BINDIR)/Sift_SiftCLI.bundle
	@echo "cli      -> $(BINDIR)/sift (+ Sift_SiftCLI.bundle)"

install-pi:
	@command -v npm >/dev/null 2>&1 || { \
		echo "npm not found — install Node first ('brew install node')." >&2; \
		exit 1; \
	}
	@mkdir -p "$(PI_DIR)"
	@echo "pi       -> installing $(PI_PACKAGE) into $(PI_DIR)"
	@cd "$(PI_DIR)" && npm install --silent --no-audit --no-fund \
		--prefix "$(PI_DIR)" $(PI_PACKAGE)
	@$(MAKE) --no-print-directory prune-pi PI_NODE_MODULES="$(PI_DIR)/node_modules"
	@echo "pi       -> $(PI_DIR)/node_modules/.bin/pi"

# Strip provider SDKs sift never invokes (it only ever uses pi's
# openai-completions API path — see Backend.swift), non-arm64 native
# binaries for koffi (the cask is Apple Silicon only), the universal
# clipboard binary (the arm64-only one stays), and TypeScript types
# (pi ships pre-compiled JS). Saves ~70 MB unpacked, ~25 MB in the zip.
# PI_NODE_MODULES is passed in by callers.
prune-pi:
	@test -n "$(PI_NODE_MODULES)" || { echo "prune-pi: PI_NODE_MODULES not set" >&2; exit 1; }
	@test -d "$(PI_NODE_MODULES)" || { echo "prune-pi: $(PI_NODE_MODULES) does not exist" >&2; exit 1; }
	@rm -rf \
		"$(PI_NODE_MODULES)/@anthropic-ai" \
		"$(PI_NODE_MODULES)/@aws-sdk" \
		"$(PI_NODE_MODULES)/@aws-crypto" \
		"$(PI_NODE_MODULES)/@smithy" \
		"$(PI_NODE_MODULES)/@google" \
		"$(PI_NODE_MODULES)/@mistralai" \
		"$(PI_NODE_MODULES)/@types" \
		"$(PI_NODE_MODULES)/@mariozechner/clipboard-darwin-universal"
	@if [ -d "$(PI_NODE_MODULES)/koffi/build/koffi" ]; then \
		find "$(PI_NODE_MODULES)/koffi/build/koffi" -mindepth 1 -maxdepth 1 -type d \
			! -name darwin_arm64 -exec rm -rf {} +; \
	fi
	@echo "pi       -> pruned unused provider SDKs and non-arm64 binaries"

uninstall:
	@rm -f $(BINDIR)/sift
	@rm -rf $(BINDIR)/Sift_SiftCLI.bundle
	@rm -rf "$(SUPPORT_DIR)"
	@echo "uninstalled. ~/.sift (vault, models, sessions) is untouched — remove it manually if you're done with sift."

run: install-cli
	$(BINDIR)/sift --help

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(RELEASE_DIR)

# Tests use swift-testing (pulled as an SPM dep) — works on Command
# Line Tools alone, no Xcode required. SIFT_HOME is pinned to a temp
# path so anything touching Paths.siftHome can't see real vault state
# (and so the project's vault-guard hook doesn't reject the run).
# --no-parallel: several suites mutate process-wide state (SIFT_HOME,
# stderr fd, URLProtocol stub queue). Cross-suite parallelism races on
# those. The whole suite runs in <100 ms anyway.
test:
	SIFT_HOME=$(shell mktemp -d -t sift-test) swift test --no-parallel

print-version:
	@echo $(VERSION)

# `make release` produces a self-contained Sift.app at $(RELEASE_DIR)/Sift.app
# with the CLI binary and the pi npm package both bundled inside, then
# zips it for upload to a GitHub Release. The Homebrew cask points at
# the resulting URL/SHA256. There's no GUI process — the bundle exists
# only so the cask can ship the CLI + pi as one signed artefact.
release: release-zip
	@echo "release  -> $(RELEASE_DIR)/$(APP_NAME)-v$(VERSION).zip"
	@echo "sha256   -> $$(/usr/bin/shasum -a 256 $(RELEASE_DIR)/$(APP_NAME)-v$(VERSION).zip | awk '{print $$1}')"

release-bundle: cli
	@command -v npm >/dev/null 2>&1 || { \
		echo "npm not found — install Node first ('brew install node')." >&2; \
		exit 1; \
	}
	@rm -rf $(RELEASE_DIR)
	@mkdir -p $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/bin
	@mkdir -p $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/pi
	@# The CLI is both the bundle's executable and the tool Paths.findExecutable
	@# resolves at Contents/Resources/bin/sift.
	@cp $(BUILD_DIR)/sift $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(BUILD_DIR)/sift $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/bin/sift
	@if [ -d $(BUILD_DIR)/Sift_SiftCLI.bundle ]; then \
		cp -R $(BUILD_DIR)/Sift_SiftCLI.bundle $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/bin/; \
	fi
	@printf '%s\n' "$$INFO_PLIST" > $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Info.plist
	@printf '%s' "APPL????" > $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/PkgInfo
	@echo "pi       -> bundling $(PI_PACKAGE) into $(APP_BUNDLE)"
	@cd $(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/pi && \
		npm install --silent --no-audit --no-fund \
		--prefix . $(PI_PACKAGE)
	@$(MAKE) --no-print-directory prune-pi \
		PI_NODE_MODULES="$(RELEASE_DIR)/$(APP_BUNDLE)/Contents/Resources/pi/node_modules"
	@echo "bundled  -> $(RELEASE_DIR)/$(APP_BUNDLE) (v$(VERSION))"

release-codesign: release-bundle
	@codesign --force --deep --sign - $(RELEASE_DIR)/$(APP_BUNDLE)
	@echo "signed   -> $(RELEASE_DIR)/$(APP_BUNDLE) (ad-hoc, deep)"

release-zip: release-codesign
	@cd $(RELEASE_DIR) && /usr/bin/ditto -c -k --keepParent $(APP_BUNDLE) $(APP_NAME)-v$(VERSION).zip

# Embedded Info.plist — kept inline so there's no separate file to get
# out of sync. The CLI is the bundle executable; no GUI, no Dock icon.
define INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>            <string>Sift</string>
  <key>CFBundleExecutable</key>             <string>Sift</string>
  <key>CFBundleIdentifier</key>             <string>$(BUNDLE_ID)</string>
  <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
  <key>CFBundleName</key>                   <string>Sift</string>
  <key>CFBundlePackageType</key>            <string>APPL</string>
  <key>CFBundleShortVersionString</key>     <string>$(VERSION)</string>
  <key>CFBundleVersion</key>                <string>$(VERSION)</string>
  <key>LSMinimumSystemVersion</key>         <string>14.0</string>
  <key>NSHumanReadableCopyright</key>       <string>MIT licensed.</string>
</dict>
</plist>
endef
export INFO_PLIST
