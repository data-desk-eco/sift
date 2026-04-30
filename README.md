# sift

A self-contained investigative research agent for OCCRP [Aleph](https://aleph.occrp.org). Runs entirely on your Mac: a local Qwen3.6 35B served by [llama.cpp](https://github.com/ggml-org/llama.cpp) drives the [`pi`](https://www.npmjs.com/package/@mariozechner/pi) agent harness, which uses an [Aleph skill](share/aleph/SKILL.md) to search, read, and pivot through documents and entities. Credentials and findings live in an encrypted sparseimage at `~/.sift`. Nothing leaves your machine but the Aleph queries themselves.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/data-desk-eco/sift/main/install.sh | bash
```

Or by hand: `brew install --HEAD data-desk-eco/tap/sift` — the qualified name is necessary because `homebrew-core` already ships an unrelated `sift` (a `grep` alternative).

## Quick start

```bash
sift init                                                    # one-time: vault + creds + model (~12 GB)
sift auto "investigate Acme Corp in the Pandora Papers"      # headless one-shot
sift auto                                                    # interactive REPL
```

In headless mode the agent appends to a `report.md` inside a per-run session directory in the vault, and prints a terse `[scope] message` log to your terminal. `--debug` dumps pi's full JSON event stream instead.

The aleph tools the agent uses are also available to you directly:

```bash
sift search query="..." [collection=<id>]
sift read alias=r5
sift vault status
```

See `sift --help` for the full list, or `sift <cmd> --help` for per-command flags.

## Requirements

- Apple Silicon Mac with **≥24 GB unified memory** (the default model uses ~14 GB at runtime)
- macOS 13 or newer
- An Aleph account with an API key

## Configuration

Environment overrides:

| | |
|---|---|
| `SIFT_HOME` | where the vault, model, and pi config live (default `~/.sift`) |
| `SIFT_BACKEND` | `llamacpp` (default) or `lmstudio` |
| `SIFT_PORT` | local LLM server port (default `1234`) |

## License

MIT.
