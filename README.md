# sift

A native macOS tool for investigating subjects in [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/). Search documents, emails, and entities directly, or let an agent run the investigation and write up what it finds.

## Quick start

```bash
# install
brew install --cask data-desk-eco/tap/sift

# one-time setup: vault, Aleph creds, LLM backend
sift init

# kick off an investigation — detaches and returns to the shell
sift auto "investigate Acme Corp in the Pandora Papers"

# watch progress (or just glance at the menu bar)
sift status
sift logs -f           # live tail, Ctrl-C to stop
```

`sift auto` prompts for a short slug to name the lead (default derived from the prompt; skip the prompt with `--slug acme`). The menu bar app surfaces the running session and notifies you when it finishes. The report lands inside the encrypted vault — `sift report` prints the markdown, `sift report --format html` renders it with live links to the source entities.

## Features

- `sift auto "PROMPT"` runs the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) agent as a detached daemon. Pass `-t 30m` for a soft deadline; `--slug` to name a fresh lead non-interactively.
- Each fresh `sift auto` becomes the active lead, so bare `sift logs`, `sift stop`, and `sift status` (marked `*`) all target it. Switch with `sift lead use <name>` or `sift lead clear` to fall back to most-recent.
- Local or hosted LLM backend. Local runs Qwen3.6 35B via [llama.cpp](https://github.com/ggml-org/llama.cpp); only Aleph queries leave the machine. Hosted accepts any OpenAI-compatible endpoint. Toggle with `sift backend local|hosted`.
- The same command surface works for humans and the agent. `sift search`, `sift read`, `sift expand`, `sift sql` are usable from the shell or driven by the agent. `sift --help` lists everything.
- The menu bar app registers an **Investigate Subject** App Intent for Shortcuts, Siri, and Raycast — bind it to a hotkey or a Stream Deck button.
- Reports, the response cache, and API keys live in a passphrase-protected sparseimage at `~/.sift/.vault.sparseimage`. The passphrase is prompted on first use after a reboot and never persisted; lose it and the vault is unrecoverable.

## Requirements

- macOS 14+ on Apple Silicon
- An Aleph or OpenAleph account with an API key
- For the local backend: ≥24 GB unified memory (~12 GB model download on first run)

## Build from source

```bash
brew install node llama.cpp
git clone https://github.com/data-desk-eco/sift && cd sift
make install
```

This is the contributor / dev path. `make install` builds, ad-hoc signs, and drops the CLI in `~/.local/bin/sift` and the app in `/Applications/Sift.app`. `make uninstall` reverses it; your vault under `~/.sift/` is preserved.

`make test` runs the test suite — uses [swift-testing](https://github.com/swiftlang/swift-testing) so it works with Command Line Tools alone (no Xcode required). CI runs the same target on every PR.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for a tour of the codebase and [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## License

MIT.
