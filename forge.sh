#!/usr/bin/env bash
# Bring up llama-server + forge-guardrails proxy + pi pointed at the proxy,
# using a small GGUF instead of the production 35B model. Mirrors the wire-up
# in Sources/SiftCore/{LlamaServer,ForgeProxy,Backend}.swift so what you test
# here is what sift auto runs in production. Bypasses the vault, Aleph creds,
# and the sift daemon entirely.
#
# Usage:
#   ./forge.sh                     # drops into pi REPL
#   ./forge.sh "your prompt"       # one-shot pi -p --mode json
#
# Tunables (env):
#   MODEL_DIR    where to cache the GGUF                 (default: ~/.cache/forge-test/models)
#   MODEL_FILE   filename inside MODEL_DIR               (default: Qwen3-1.7B-Q4_K_M.gguf)
#   MODEL_URL    download source if MODEL_FILE missing   (default: unsloth/Qwen3-1.7B-GGUF)
#   MODEL_ID     identifier pi uses to address the model (default: qwen3-1.7b)
#   LLAMA_PORT   llama-server bind port                  (default: 1234)
#   FORGE_PORT   forge proxy bind port                   (default: 8081)
#   PI_CFG_DIR   pi config dir (models.json/settings.json) (default: ~/.cache/forge-test/pi)
#   LOG_DIR      where llama/forge stdout+stderr go       (default: ~/.cache/forge-test/logs)
set -euo pipefail

MODEL_DIR="${MODEL_DIR:-$HOME/.cache/forge-test/models}"
MODEL_FILE="${MODEL_FILE:-Qwen3-1.7B-Q4_K_M.gguf}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/${MODEL_FILE}}"
MODEL_ID="${MODEL_ID:-qwen3-1.7b}"
LLAMA_PORT="${LLAMA_PORT:-1234}"
FORGE_PORT="${FORGE_PORT:-8081}"
PI_CFG_DIR="${PI_CFG_DIR:-$HOME/.cache/forge-test/pi}"
LOG_DIR="${LOG_DIR:-$HOME/.cache/forge-test/logs}"

mkdir -p "$MODEL_DIR" "$PI_CFG_DIR" "$LOG_DIR"

say() { printf '[forge.sh] %s\n' "$*"; }
die() { printf '[forge.sh] %s\n' "$*" >&2; exit 1; }

for tool in llama-server uv pi curl; do
  command -v "$tool" >/dev/null || die "missing dependency: $tool"
done

# --- model -------------------------------------------------------------------

if [ ! -f "$MODEL_DIR/$MODEL_FILE" ]; then
  say "downloading $MODEL_FILE (~1.1 GB) -> $MODEL_DIR"
  curl --fail --progress-bar --retry 5 --retry-all-errors -L \
    -o "$MODEL_DIR/$MODEL_FILE.partial" "$MODEL_URL"
  mv "$MODEL_DIR/$MODEL_FILE.partial" "$MODEL_DIR/$MODEL_FILE"
fi

# --- pi config ---------------------------------------------------------------
# Shape mirrors Backend.configurePi() so pi sees forge exactly the way it would
# under `sift auto`.

cat >"$PI_CFG_DIR/models.json" <<JSON
{
  "providers": {
    "sift": {
      "baseUrl": "http://127.0.0.1:${FORGE_PORT}/v1",
      "api": "openai-completions",
      "apiKey": "forge-test",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        { "id": "${MODEL_ID}", "name": "${MODEL_ID} (forge test)", "contextWindow": 32768 }
      ]
    }
  }
}
JSON

cat >"$PI_CFG_DIR/settings.json" <<JSON
{ "defaultProvider": "sift", "defaultModel": "${MODEL_ID}" }
JSON

# --- cleanup trap ------------------------------------------------------------

LLAMA_PID=""; FORGE_PID=""
cleanup() {
  local code=$?
  trap - EXIT INT TERM
  if [ -n "$FORGE_PID" ] && kill -0 "$FORGE_PID" 2>/dev/null; then
    say "stopping forge proxy (pid $FORGE_PID)"
    kill -TERM "$FORGE_PID" 2>/dev/null || true
    wait "$FORGE_PID" 2>/dev/null || true
  fi
  if [ -n "$LLAMA_PID" ] && kill -0 "$LLAMA_PID" 2>/dev/null; then
    say "stopping llama-server (pid $LLAMA_PID)"
    kill -TERM "$LLAMA_PID" 2>/dev/null || true
    wait "$LLAMA_PID" 2>/dev/null || true
  fi
  exit $code
}
trap cleanup EXIT INT TERM

wait_for_http() {
  local label="$1" url="$2" deadline=$((SECONDS + 120))
  while [ $SECONDS -lt $deadline ]; do
    if curl -fsS -m 1 "$url" >/dev/null 2>&1; then
      say "$label ready"
      return 0
    fi
    sleep 1
  done
  die "$label didn't become ready in 120s (see $LOG_DIR)"
}

# --- llama-server (flags mirror LlamaServer.startLocal) ----------------------

say "starting llama-server on :$LLAMA_PORT -> $MODEL_FILE"
llama-server \
  --model "$MODEL_DIR/$MODEL_FILE" \
  --host 127.0.0.1 --port "$LLAMA_PORT" \
  --jinja --no-webui \
  --ctx-size 32768 \
  --flash-attn on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --alias "$MODEL_ID" \
  >"$LOG_DIR/llama-server.log" 2>&1 &
LLAMA_PID=$!
wait_for_http "llama-server" "http://127.0.0.1:${LLAMA_PORT}/v1/models"

# --- forge proxy (command mirrors ForgeProxy.start) --------------------------

say "starting forge proxy on :$FORGE_PORT -> llama :$LLAMA_PORT"
uv run --with forge-guardrails --no-project --python 3.12 \
  python -m forge.proxy \
  --backend-url "http://127.0.0.1:${LLAMA_PORT}" \
  --port "$FORGE_PORT" \
  >"$LOG_DIR/forge-proxy.log" 2>&1 &
FORGE_PID=$!
wait_for_http "forge proxy" "http://127.0.0.1:${FORGE_PORT}/v1/models"

# --- pi ----------------------------------------------------------------------

say "launching pi (config: $PI_CFG_DIR)"
export PI_CODING_AGENT_DIR="$PI_CFG_DIR"
export PI_OFFLINE=1
if [ $# -gt 0 ]; then
  pi -p --mode json "$@"
else
  pi
fi
