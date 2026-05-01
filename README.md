# sift

A native macOS tool for investigating subjects in [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/). Search documents, emails, and entities; follow extracted links; or let an agent drive an investigation end-to-end and write up what it finds.

## Quick start

```bash
# install
brew install --cask data-desk-eco/sift/sift

# one-time setup: vault, Aleph creds, LLM backend
sift init

# kick off an investigation — detaches and returns to the shell
sift auto "investigate Acme Corp in the Pandora Papers"

# watch progress (or just glance at the menu bar)
sift status
sift logs -f
sift attach            # live view, q to detach
```

After the third command the menu bar app pops up, the agent runs in the background, and you get a notification when it's done. The report lands in your encrypted vault — `sift export` renders it to HTML with live links to the source entities.

## Highlights

- **`sift auto "PROMPT"`** runs the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) agent as a detached daemon. Pass `-t 30m` for a soft deadline.
- **Active lead.** Each fresh `sift auto` becomes your default session — bare `sift logs`, `sift attach`, `sift stop`, and `sift status` (marked `*`) all target it. Switch with `sift lead <session>`.
- **Two LLM backends.** Local Qwen3.6 35B via [llama.cpp](https://github.com/ggml-org/llama.cpp) (nothing leaves your Mac except Aleph queries) or any hosted OpenAI-compatible endpoint. Toggle with `sift backend local|hosted`.
- **One CLI for humans and agents.** `sift search`, `sift read`, `sift expand`, `sift sql` all work standalone — call them yourself or let the agent drive them. `sift --help` lists everything.
- **Shortcuts / Siri / Raycast.** The menu bar app registers an **Investigate Subject** App Intent — wire it to a hotkey, a Stream Deck button, or "Hey Siri, investigate X with sift".
- **Encrypted by default.** Reports and the local cache live in a Touch-ID-gated sparseimage at `~/.sift/`; API keys live in the macOS Keychain.

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

## License

MIT.
