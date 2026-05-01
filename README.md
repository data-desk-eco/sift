# sift

A native macOS tool for investigating subjects in [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/). Search documents, emails, and entities; follow extracted links; let an agent drive an investigation end-to-end. Credentials live in the Touch-ID-gated macOS Keychain; reports and the local cache live in an encrypted sparseimage at `~/.sift/.vault.sparseimage`.

## Quick start

```bash
# 1. install (Homebrew + a build of sift, ad-hoc signed, into ~/.local/bin and /Applications)
curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash

# 2. one-time setup: vault passphrase, Aleph creds, LLM backend, project description
sift init

# 3. kick off an investigation — detaches and returns to the shell
sift auto "investigate Acme Corp in the Pandora Papers"

# 4. watch progress (any of these, or just glance at the menu bar)
sift status
sift logs -f
sift attach            # live SwiftTUI view, q to detach
```

After step 3 the menu bar app auto-launches, the agent runs in the background, and you get a notification when it's done. `report.md` lands inside the encrypted vault — render it to HTML with `sift export` (alias references become live links).

## What you get

- **`sift auto "PROMPT"`** runs the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) agent as a detached daemon. Live progress in the menu bar, `sift status`, or `sift logs -f`. Pass `-t 30m` for a soft deadline; the agent paces itself with `sift time`.
- **Active lead.** Each fresh `sift auto` pins the session as your active lead in `~/.sift/active-lead`. Bare `sift logs`, `sift attach`, `sift stop`, and `sift status` (marked `*`) default to it, so a normal day is one `sift auto "…"` and then bare verbs. Switch with `sift lead <session>`, clear with `sift lead --clear`.
- **Two LLM backends.** Local Qwen3.6 35B served by [llama.cpp](https://github.com/ggml-org/llama.cpp) (default — nothing leaves the machine except Aleph queries) or any hosted OpenAI-compatible endpoint. Switch with `sift backend local|hosted`. llama-server is reaped automatically when no auto session is running, so it doesn't pin ~14 GB of unified memory while idle.
- **Same commands for humans and agents.** `sift search`, `sift read`, `sift expand`, `sift browse`, `sift sql` all work standalone — call them at the prompt or let the agent drive them. `sift --help` lists everything.
- **Shortcuts / Siri / Raycast.** The menu bar app registers an **Investigate Subject** App Intent. Wire it to a global hotkey, a Stream Deck button, or "Hey Siri, investigate X with sift" via Shortcuts.app.

## Manual install

```bash
brew install node llama.cpp
git clone https://github.com/data-desk-eco/sift && cd sift
make install   # builds, ad-hoc signs, bundles pi locally; no npm globals
```

`~/.local/bin` must be on `PATH`. Wipe with `make uninstall` (vault state under `~/.sift/` is preserved).

## Requirements

- macOS 14 (Sonoma) or newer on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- For the local backend: ≥24 GB unified memory (default model uses ~14 GB at runtime, ~12 GB download on first run)
- An Aleph or OpenAleph account with an API key

## State layout

Everything under `~/.sift/`:

- `.vault.sparseimage` — encrypted volume; per-session research dirs hold `report.md`, `aleph.sqlite`, `auto.log`, `pi-sessions/`
- `backend.json` (mode 0600) — backend kind, model, port, base URL (no secrets)
- `models/` — GGUF model files for the local backend
- `pi/` — `models.json` + `settings.json` regenerated each run from `backend.json` (the pi *binary* lives in `~/Library/Application Support/Sift/pi/`)
- `run/<session>.json` — live state per detached `sift auto` run; the menu bar app watches this directory
- `active-lead` — current default session for bare `auto`/`logs`/`attach`/`stop`
- `project.md` — optional one-line project description prepended to the agent's system prompt

Secrets (vault passphrase, Aleph API key, hosted-backend API key) live in the **macOS Keychain** under service `eco.datadesk.sift`.

## License

MIT.
