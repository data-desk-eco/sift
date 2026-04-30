#!/usr/bin/env bash
# sift installer — bootstraps Homebrew (if needed) and installs sift.
# Run via:  curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "sift currently supports macOS only." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "sift requires an Apple Silicon Mac (M1/M2/M3/M4)." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — installing it first."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

echo "Installing sift from data-desk-eco/tap..."
# Qualified name avoids a collision with homebrew-core's `sift` (the Go
# debugger). --HEAD until v0.1.0 is tagged with a real tarball sha256.
brew install --HEAD data-desk-eco/tap/sift

cat <<'EOF'

sift installed. Next:

  sift init                       # one-time: vault, Aleph credentials, model (~12GB)
  sift auto "investigate ..."     # headless one-shot
  sift auto                       # interactive REPL
  sift --help                     # full command list, including direct aleph tools

EOF
