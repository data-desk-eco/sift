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
  auto                    Sweep a list of topics through the collection, one
                          agent per topic.
```

The Aleph and memory subcommands are the working surface. Each one takes a query or an alias and prints results to stdout; results from one command (`r5`, `d3491`, …) feed straight into the next. Aliases are stable across sessions on the same vault, so `r5` resolves to the same entity tomorrow. Responses are cached locally, so re-running the same call is free.

`sift <command> --help` lists flags for any subcommand.

## Sweeping a list of topics

The same tools can be driven by an LLM. `sift auto LIST.txt` takes a worklist — one topic per line — and works through it sequentially: for each topic it boots a fresh, short-lived agent that searches, reads, and pivots through the collection, then records what it finds as [FollowTheMoney](https://followthemoney.tech) entities.

```bash
cat > sanctions.txt <<'EOF'
EU 833/2014 Art. 3 — dual-use goods/technology to Russia
EU 833/2014 Art. 5 — sovereign-debt and securities restrictions
designated banks: Bank Rossiya, SMP Bank
EOF

sift auto sanctions.txt          # sweep every line, one agent each
sift auto -t 30m sanctions.txt   # 30 minutes per topic
```

Each topic gets its own bounded context, so the local model never bogs down dragging one investigation's history into the next — the reason the sweep beats a single long-running agent on a laptop. Findings accumulate in a shared `findings.db` and a running `report.md`; every few topics a consolidation pass distils progress into a digest that's fed forward. An agent that surfaces a fresh lead appends it to the worklist with `sift queue`, so the sweep grows as it goes. The worklist file is the only state — open it mid-run and you see what's done (`✓`), what's pending, and what's been discovered.

`findings.db` is FollowTheMoney all the way down, so you can upload it straight back into Aleph to thread your findings into the existing entity graph.

The agent runs against either a local LLM (Qwen3 via [llama.cpp](https://github.com/ggml-org/llama.cpp), so only Aleph traffic leaves the machine) or any OpenAI-compatible hosted endpoint. Toggle with `sift backend local|hosted`. It's built on the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) harness; the bundled skill file documents the tool surface and a few Aleph quirks for the model.

## Quick start

```bash
brew install --cask data-desk-eco/tap/sift

sift init                              # vault, Aleph creds, LLM backend
sift search "acme corp"                # use the tools directly, or:
sift auto topics.txt                   # let the agent sweep a worklist
```

`sift init` creates an encrypted sparseimage at `~/.sift/.vault.sparseimage` and asks for a passphrase. The passphrase is prompted on first use after each reboot and never persisted — losing it is unrecoverable. Aleph keys, the response cache, and every report live inside the vault.

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

`make install` builds and drops the CLI in `~/.local/bin/sift` (plus the pi harness in `~/Library/Application Support/Sift/`). `make uninstall` reverses it; the vault under `~/.sift/` is preserved. `make test` runs the suite via [swift-testing](https://github.com/swiftlang/swift-testing) — no Xcode required.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for a tour of the codebase and [`CHANGELOG.md`](CHANGELOG.md) for release notes.

## License

MIT.
