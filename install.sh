#!/usr/bin/env bash
# delve installer — bootstraps Homebrew (if needed) and installs delve.
# Run via:  curl -fsSL https://raw.githubusercontent.com/data-desk-eco/delve/main/install.sh | bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "delve currently supports macOS only." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "delve requires an Apple Silicon Mac (M1/M2/M3/M4)." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — installing it first."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

echo "Installing delve from data-desk-eco/tap..."
# Qualified name avoids a collision with homebrew-core's `delve` (the Go
# debugger). --HEAD until v0.1.0 is tagged with a real tarball sha256.
brew install --HEAD data-desk-eco/tap/delve

cat <<'EOF'

delve installed. Next:

  delve init                 # one-time: vault, Aleph credentials, model (~12GB)
  delve "investigate ..."    # headless one-shot
  delve                      # interactive REPL

EOF
