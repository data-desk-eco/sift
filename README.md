# sift

A CLI for investigating subjects in [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/) — search documents, emails, and entities, follow extracted links, browse folder trees. Credentials and findings live in an encrypted sparseimage at `~/.sift`.

It's the same surface for humans and agents: `sift search`, `sift read`, `sift vault …` are what you type at the prompt, and they're also what an agent calls when you run `sift auto "investigate …"`. Self-automating: `sift auto` drives the [`pi`](https://www.npmjs.com/package/@mariozechner/pi) harness with [a small skill file](share/SKILL.md) and lets the agent loop over the same `sift` you use directly. The LLM backend is your choice — a local Qwen3.6 35B served by [llama.cpp](https://github.com/ggml-org/llama.cpp) (default; nothing leaves your machine but Aleph queries) or any hosted OpenAI-compatible endpoint (LM Studio, Ollama, OpenAI, …).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash
```

Or by hand: `brew install --HEAD data-desk-eco/tap/sift` — the qualified name is necessary because `homebrew-core` already ships an unrelated `sift` (a `grep` alternative).

## Quick start

```bash
sift init                                                    # one-time: vault, creds, LLM backend
sift auto "investigate Acme Corp in the Pandora Papers"      # headless one-shot
sift auto                                                    # interactive REPL
```

`sift init` asks whether you want the recommended local backend (downloads ~12 GB on first run) or a hosted OpenAI-compatible endpoint (URL + key + model). Switch later with `sift backend local` / `sift backend hosted`.

In headless mode the agent appends to a `report.md` inside a per-run session directory in the vault, and prints a terse `[scope] message` log to your terminal. `--debug` dumps pi's full JSON event stream instead.

The same tools the agent uses are available to you directly:

```bash
sift search query="..." [collection=<id>]
sift read alias=r5
sift vault status
```

See `sift --help` for the full list, or `sift <cmd> --help` for per-command flags.

## Requirements

- macOS 13 or newer on Apple Silicon
- For the local backend: ≥24 GB unified memory (the default model uses ~14 GB at runtime)
- An Aleph or OpenAleph account with an API key

## Configuration

Environment overrides:

| | |
|---|---|
| `SIFT_HOME` | where the vault, model, and pi config live (default `~/.sift`) |
| `SIFT_PORT` | local LLM server port (default `1234`, local backend only) |

Backend config (kind, URL, key, model name) lives in `~/.sift/backend.json` (mode 0600).

## License

MIT.
