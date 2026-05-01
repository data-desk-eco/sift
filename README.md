# sift

A CLI for investigating subjects in [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/) — search documents, emails, and entities, follow extracted links, browse folder trees. Credentials and findings live in an encrypted sparseimage at `~/.sift`.

The command surface is shared between humans and agents: `sift search`, `sift read`, `sift vault …` work the same whether invoked at the prompt or called by the agent under `sift auto "investigate …"`. `sift auto` drives the [`pi`](https://www.npmjs.com/package/@mariozechner/pi) harness with [a small skill file](share/SKILL.md), giving the agent access to the same commands. Two LLM backends are supported: a local Qwen3.6 35B served by [llama.cpp](https://github.com/ggml-org/llama.cpp) (default; nothing leaves the machine except Aleph queries), or any hosted OpenAI-compatible endpoint (LM Studio, Ollama, OpenAI, …).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash
```

The installer pulls in runtime dependencies via Homebrew (`uv`, `node`, `llama.cpp`) and the [`pi`](https://www.npmjs.com/package/@mariozechner/pi) agent harness via npm, then installs sift itself with `uv tool install`. `~/.local/bin` must be on `PATH`.

To install manually: `brew install uv node llama.cpp && npm install -g @mariozechner/pi && uv tool install git+https://github.com/data-desk-eco/sift`.

## Quick start

```bash
sift init                                                    # one-time: vault, creds, LLM backend
sift auto "investigate Acme Corp in the Pandora Papers"      # headless one-shot
sift auto "find more leads"                                  # continues the same session
sift auto --new "investigate Beta Corp"                      # fresh session for a new subject
sift auto -t 30m "investigate Acme Corp"                     # with a soft deadline
sift auto                                                    # interactive REPL
```

`sift init` prompts for either the recommended local backend (downloads ~12 GB on first run) or a hosted OpenAI-compatible endpoint (URL, key, and model). Switch later with `sift backend local` or `sift backend hosted`.

It also prompts for a one-line project description (data source and subject of investigation), which is prepended to the agent's system prompt on every run. View or change it with `sift project [show|set|edit|clear]`.

By default `sift auto` continues the most recent session — pi reloads its conversation history and the agent's cwd is the original session dir, so `report.md` and `findings.db` keep growing in place. Pass `--new` to start fresh; sift also warns if the session you'd be resuming is more than a day old, in case you meant a different subject. The agent writes to `report.md` inside the encrypted vault and emits a terse `[scope] message` log to the terminal. `--debug` emits pi's full JSON event stream instead.

`-t / --time-limit` (e.g. `30m`, `1h30m`, `90s`) sets a soft deadline. The agent paces itself against the deadline by calling `sift time` between tool calls. The deadline is not enforced, but the agent is instructed to stop opening new threads as it approaches and to finalise `report.md` before exiting.

The agent's tools are also available directly:

```bash
sift search "..." [--collection <id>]
sift read r5
sift vault status
```

See `sift --help` for the full list, or `sift <cmd> --help` for per-command flags.

## Requirements

- macOS 13 or newer on Apple Silicon
- For the local backend: ≥24 GB unified memory (the default model uses ~14 GB at runtime)
- An Aleph or OpenAleph account with an API key

## Configuration

All state is stored under `~/.sift`:

- `.vault.sparseimage` — encrypted volume holding API keys and per-investigation `report.md` outputs
- `backend.json` (mode 0600) — backend kind, model, URL/key, and the local-server port
- `models/` — GGUF model files for the local backend
- `pi/` — configuration for the agent harness
- `project.md` — optional one-line project description, prepended to the agent's system prompt

## License

MIT.
