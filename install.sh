#!/usr/bin/env bash
# sift installer — clones the repo, builds the Swift binary + menu bar
# app, and drops them in ~/.local/bin and /Applications.
# Run via:  curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash

set -euo pipefail

# Quiet Homebrew chatter; real failures still print on stderr.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "sift currently supports macOS only." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "sift requires an Apple Silicon Mac (M1/M2/M3/M4)." >&2
  exit 1
fi

# We need Xcode Command Line Tools for swiftc. xcode-select returns a
# valid path if anything's installed; trigger the GUI installer otherwise.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools not found — triggering the installer."
  xcode-select --install || true
  echo "Re-run this installer once the dialog finishes."
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — installing it first."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Runtime deps: pi is the agent harness; llama.cpp serves the local
# model; node hosts pi.
missing=()
for formula in node llama.cpp; do
  brew list --formula "$formula" >/dev/null 2>&1 || missing+=("$formula")
done
if (( ${#missing[@]} > 0 )); then
  echo "Installing runtime dependencies via Homebrew: ${missing[*]}"
  brew install "${missing[@]}" >/dev/null
fi

# pi is installed locally under Application Support/Sift, not as a
# global npm package — keeps multiple sift installs independent and
# makes uninstalling clean. The Makefile's install-pi target does the
# actual work; we just make sure npm is available before we get there.
if ! command -v npm >/dev/null 2>&1; then
  echo "npm should have been installed with node — bailing out." >&2
  exit 1
fi

# Where to keep the source tree. Use a stable path so re-runs do an
# update rather than re-clone, and so the user can `cd` in to inspect.
SIFT_SRC="${SIFT_SRC:-$HOME/Library/Application Support/Sift/src}"
mkdir -p "$(dirname "$SIFT_SRC")"

if [[ -d "$SIFT_SRC/.git" ]]; then
  echo "Updating sift sources at $SIFT_SRC..."
  git -C "$SIFT_SRC" fetch --quiet origin
  git -C "$SIFT_SRC" reset --quiet --hard origin/main
else
  echo "Cloning sift sources to $SIFT_SRC..."
  git clone --quiet https://github.com/data-desk-eco/sift "$SIFT_SRC"
fi

echo "Building sift (this takes a minute on first run)..."
make -C "$SIFT_SRC" --quiet install

cat <<'EOF'

sift installed. Make sure ~/.local/bin is on your PATH.

Next:

  sift init                       # one-time: vault, Aleph credentials, model (~12GB)
  sift auto "investigate ..."     # headless one-shot, returns to shell
  sift status                     # check what's running
  sift auto                       # interactive REPL
  sift --help                     # full command list

The menu bar item (Sift.app) is in /Applications. Open it once to see
live progress; Shortcuts.app picks up the "Investigate Subject" action
the same way.

EOF
