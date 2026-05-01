# sift

A native macOS tool for investigating subjects in [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/) — search documents, emails, and entities, follow extracted links, browse folder trees. Credentials live in the macOS Keychain (Touch ID gated); reports and the local cache live in an encrypted sparseimage at `~/.sift/.vault.sparseimage`.

The Aleph query commands (`sift search`, `sift read`, `sift expand`, …) are shared between humans and agents — call them yourself or let `sift auto` drive them. `sift auto "PROMPT"` runs the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) agent as a detached daemon and returns to the shell; the menu bar app pops up automatically to show live progress, posts a notification when done, and gives one-click access to `report.md`. Two LLM backends are supported: a local Qwen3.6 35B served by [llama.cpp](https://github.com/ggml-org/llama.cpp) (default; nothing leaves the machine except Aleph queries), or any hosted OpenAI-compatible endpoint (LM Studio, Ollama, OpenAI, …). When the last running session ends, sift kills llama-server so it doesn't keep ~14 GB pinned in unified memory.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash
```

The installer pulls in runtime dependencies via Homebrew (`node`, `llama.cpp`), clones the source tree to `~/Library/Application Support/Sift/src`, builds the Swift binary + menu bar app with `swift build -c release`, ad-hoc codesigns them, installs the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) agent harness locally into `~/Library/Application Support/Sift/pi/` (no npm globals are touched), and drops `sift` in `~/.local/bin/` and `Sift.app` in `/Applications/`. `~/.local/bin` must be on `PATH`. To remove everything later: `make uninstall`.

To install manually:

```bash
brew install node llama.cpp
git clone https://github.com/data-desk-eco/sift && cd sift
make install   # builds, ad-hoc signs, and bundles pi into ~/Library/Application Support/Sift/
```

## Quick start

```bash
sift init                                                    # one-time: vault, creds, LLM backend
sift auto "investigate Acme Corp in the Pandora Papers"      # headless one-shot, returns to shell
sift status                                                  # see what's running
sift logs -f                                                 # follow the live log
sift auto                                                    # interactive REPL (foreground)
```

`sift auto "PROMPT"` detaches and returns to the shell immediately. Live progress is visible in three places:

- the **menu bar item** (`Sift.app`) — shows the current scope and click-through to tail the log, open the session folder, or stop the run
- `sift status` — terse summary of running and recent sessions
- `sift logs -f [SESSION]` — tail the per-session log

When the agent finishes you'll get a macOS notification with the session name. The rendered `report.md` lives inside the encrypted vault; render it to HTML with `sift export` (alias references become live links to entities on the source Aleph server).

`sift init` prompts for either the recommended local backend (downloads ~12 GB on first run) or a hosted OpenAI-compatible endpoint. Switch later with `sift backend local` or `sift backend hosted`. It also prompts for a one-line project description (data source and subject of investigation), which is prepended to the agent's system prompt on every run. View or change it with `sift project [show|set|edit|clear]`.

By default `sift auto` continues your **active lead** — the last fresh session you started, pinned in `~/.sift/active-lead`. `sift logs`, `sift attach`, `sift stop`, and `sift status` (where the lead is marked with `*`) all default to it too, so a normal day is `sift auto "…"` once and then bare verbs after that. Switch leads with `sift lead <session>`, or `sift lead --clear` to fall back to "most recent". Pass `--new` to start a fresh session (and pin it as the new lead); sift warns if a resumed session is more than a day old. `-t / --time-limit` (e.g. `30m`, `1h30m`, `90s`) sets a soft deadline; the agent paces itself by calling `sift time` between tool calls.

The agent's tools are also available directly:

```bash
sift search "..." [--collection <id>]
sift read r5
sift expand r3
sift sql "select count(*) from entities where schema='Email'"
```

See `sift --help` for the full list, or `sift <cmd> --help` for per-command flags.

### Shortcuts / Siri / Raycast

The menu bar app registers an **Investigate Subject** App Intent. Open Shortcuts.app to wire it into a global hotkey, a Stream Deck button, or "Hey Siri, investigate X with sift". Raycast picks it up automatically via the Apple Intents bridge.

## Requirements

- macOS 14 (Sonoma) or newer on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- For the local backend: ≥24 GB unified memory (the default model uses ~14 GB at runtime)
- An Aleph or OpenAleph account with an API key

## Configuration

State lives under `~/.sift/`:

- `.vault.sparseimage` — encrypted volume holding the per-session research dirs (each with `report.md`, `aleph.sqlite`, `auto.log`, `pi-sessions/`)
- `backend.json` (mode 0600) — backend kind, model, port, base URL (no secrets)
- `models/` — GGUF model files for the local backend
- `pi/` — `models.json` and `settings.json` written by sift each run so pi talks to the configured backend (the pi *binary* itself lives separately, in `~/Library/Application Support/Sift/pi/`)
- `run/<session>.json` — live state per detached `sift auto` run; the menu bar app watches this directory
- `active-lead` — name of the session that bare `sift auto`/`logs`/`attach`/`stop` default to
- `project.md` — optional one-line project description prepended to the agent's system prompt

Secrets (vault passphrase, Aleph API key, hosted-backend API key) live in the **macOS Keychain** under the `eco.datadesk.sift` service.

## License

MIT.
