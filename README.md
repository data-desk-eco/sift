# sift

A native macOS tool for investigating subjects in [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/). It exposes the Aleph collection as a small set of command-line tools — search, read, expand links, browse folders, find name variants — and keeps credentials and research products in an encrypted vault.

## The tools

```
$ sift
OVERVIEW: Investigate subjects in Aleph or OpenAleph from your Mac.

USAGE: sift <subcommand>

ALEPH SUBCOMMANDS:
  search                  Search the collection for hits.
  read                    Pull the full content of an entity by alias.
  sources                 List Aleph collections visible to your API key.
  hubs                    Top emitters / recipients / mentions for entities
                          matching a query.
  similar                 Aleph-extracted name-variant candidates for a party
                          entity.
  expand                  Show entities linked via FtM property refs.
  browse                  Filesystem-style: parent folder and siblings.
  tree                    ASCII subtree of a folder or collection roots.
  neighbours              Show every cached edge touching an entity.

MEMORY SUBCOMMANDS:
  recall                  Summarise what's in the local cache.
  sql                     Read-only SQL against the cache DB.
  cache                   Inspect or prune the local response cache.
  report                  Print or render a lead's report.md.
  time                    Show remaining time and pacing for the current
                          session.

SETUP SUBCOMMANDS:
  init                    One-time setup: vault, Aleph credentials, LLM
                          backend, project.
  vault                   Vault management.
  backend                 Show or switch the LLM backend.
  project                 Show or edit the project description prepended to the
                          agent's system prompt.

AUTO SUBCOMMANDS:
  auto                    Run the agent. Returns to the shell once a detached
                          run starts.
  lead                    Show or switch the active lead.
  status                  Show running and recently-finished leads.
  logs                    Tail the active lead's log (or the named lead's).
  stop                    Stop the running lead's agent.
```

The Aleph and memory subcommands are the working surface. Each one takes a query or an alias and prints results to stdout; results from one command (`r5`, `d3491`, …) feed straight into the next. Aliases are stable across sessions on the same vault, so `r5` resolves to the same entity tomorrow. Responses are cached locally, so re-running the same call is free.

`sift <command> --help` lists flags for any subcommand.

## Driving the tools in a loop

The same tools can be driven by an LLM. `sift auto "PROMPT"` starts an agent with the Aleph and memory commands available to it, lets it search, read, and expand its way through the collection, and writes a report at the end.

```bash
sift auto "investigate Acme Corp in the Pandora Papers"
sift auto -t 30m "trace shipments from X to Y in the leaked manifests"
```

The run detaches and returns to the shell. `sift status` shows active and recent leads; `sift logs -f` tails the live transcript; the menu bar app surfaces the same state and notifies on completion. Reports land inside the vault — `sift report` prints the markdown, `sift report --format html` renders it with live links to the source entities.

The agent runs against either a local LLM (Qwen3 35B via [llama.cpp](https://github.com/ggml-org/llama.cpp), so only Aleph traffic leaves the machine) or any OpenAI-compatible hosted endpoint. Toggle with `sift backend local|hosted`.

`sift auto` is built on the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) harness; the bundled skill file documents the tool surface and a few Aleph quirks for the model.

## Quick start

```bash
brew install --cask data-desk-eco/tap/sift

sift init                              # vault, Aleph creds, LLM backend
sift search "acme corp"                # use the tools directly, or:
sift auto "investigate Acme Corp"      # let the agent drive
```

`sift init` creates an encrypted sparseimage at `~/.sift/.vault.sparseimage` and asks for a passphrase. The passphrase is prompted on first use after each reboot and never persisted — losing it is unrecoverable. Aleph keys, the response cache, and every report live inside the vault.

The menu bar app registers an **Investigate Subject** App Intent for Shortcuts, Siri, and Raycast.

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

`make install` builds, ad-hoc signs, and drops the CLI in `~/.local/bin/sift` and the app in `/Applications/Sift.app`. `make uninstall` reverses it; the vault under `~/.sift/` is preserved. `make test` runs the suite via [swift-testing](https://github.com/swiftlang/swift-testing) — no Xcode required.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for a tour of the codebase and [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## License

MIT.
