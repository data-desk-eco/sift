#!/usr/bin/env bash
# sift installer — bootstraps Homebrew (for runtime deps) and uv, then
# installs sift itself with `uv tool install`.
# Run via:  curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash

set -euo pipefail

# Quieter Homebrew: skip the auto-update banner that runs on every
# install, and silence the post-install env-hint nag. Real failures
# still print on stderr.
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

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — installing it first."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Runtime deps. uv ships sift; pi is the agent harness; llama.cpp serves
# the local model; node is needed for the npm-installed pi.
missing=()
for formula in uv node llama.cpp; do
  brew list --formula "$formula" >/dev/null 2>&1 || missing+=("$formula")
done
if (( ${#missing[@]} > 0 )); then
  echo "Installing runtime dependencies via Homebrew: ${missing[*]}"
  brew install "${missing[@]}" >/dev/null
fi

if ! command -v pi >/dev/null 2>&1; then
  echo "Installing the pi agent harness..."
  npm install -g --loglevel=error @mariozechner/pi
fi

# If a previous (pre-0.2) Homebrew-installed sift is on PATH, get rid of
# it so the uv-installed binary wins.
if brew list --formula 2>/dev/null | grep -qx sift; then
  echo "Removing legacy Homebrew sift install..."
  brew uninstall sift >/dev/null
fi

echo "Installing sift..."
uv tool install --force --quiet git+https://github.com/data-desk-eco/sift

cat <<'EOF'

sift installed. Make sure ~/.local/bin is on your PATH (uv tool's default).

Next:

  sift init                       # one-time: vault, Aleph credentials, model (~12GB)
  sift auto "investigate ..."     # headless one-shot
  sift auto                       # interactive REPL
  sift --help                     # full command list

EOF
