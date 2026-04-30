# delve

An investigative research agent that runs entirely on your Mac. Talks to an [OCCRP Aleph](https://aleph.occrp.org) instance, and uses a local Qwen3.6 35B A3B (served by [llama.cpp](https://github.com/ggml-org/llama.cpp)) as the brain. Credentials and research products live in an encrypted sparseimage; nothing leaves your machine except the Aleph API queries themselves.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/data-desk-eco/delve/main/install.sh | bash
```

This installs Homebrew (if you don't have it), then `brew install`s the dependencies (`llama.cpp`, `node`, `uv`), the [`pi` agent harness](https://www.npmjs.com/package/@mariozechner/pi), and `delve` itself.

If you'd rather install by hand:

```bash
brew install --HEAD data-desk-eco/tap/delve
```

(The qualified name is necessary — `homebrew-core` ships an unrelated `delve` formula for the Go debugger.)

## Setup

```bash
delve init
```

One-time. Creates an encrypted vault at `~/.delve/.vault.sparseimage`, prompts for your Aleph URL and API key (stored inside the vault), and downloads the default model (~12GB).

## Use

```bash
delve "investigate Acme Corp's offshore exposure in the Pandora Papers"
```

Headless, one-shot. The agent works through the dataset and writes a `report.md` into a session directory inside the encrypted vault. The terminal shows a terse `[scope] message` log of what it's doing.

```bash
delve
```

Interactive REPL — drop into `pi` directly with the aleph skill loaded.

```bash
delve --debug "..."
```

Same as headless, but dumps the full pi event stream as raw JSON instead of the formatted log.

## Requirements

- Apple Silicon Mac with at least 24 GB unified memory (the default model needs ~14 GB at runtime; `delve` will download ~12 GB on first init)
- macOS 13 or newer
- An Aleph account with an API key

## Configuration

Environment variables:

- `DELVE_HOME` — where the vault, model, and pi config live (default `~/.delve`)
- `DELVE_BACKEND` — `llamacpp` (default) or `lmstudio`
- `DELVE_PORT` — port the local LLM server listens on (default `1234`)

## What's inside

- [`bin/delve`](bin/delve) — the CLI
- [`bin/delve-log.py`](bin/delve-log.py) — formats `pi`'s JSON event stream into a terse `[scope] message` log
- [`share/aleph/`](share/aleph) — the [Aleph skill](share/aleph/SKILL.md): a Python CLI giving the agent search/read/expand/browse tools over an Aleph instance, plus a TouchID-gated encrypted-sparseimage vault
- [`share/AGENTS.md`](share/AGENTS.md) — the system prompt appended for every session

## License

MIT.
