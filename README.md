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
  report                  Print a lead's report.md.
  time                    Show remaining time and pacing for the current
                          session.

LEADS SUBCOMMANDS:
  queue                   Add a topic to this run's worklist for a later
                          session.
  note                    Append a finding to this topic's segment of the
                          report.

SETUP SUBCOMMANDS:
  init                    One-time setup: vault, Aleph credentials, LLM
                          backend, project.
  vault                   Vault management.
  backend                 Show or switch the LLM backend.
  project                 Show or edit the project description prepended to the
                          agent's system prompt.

AUTO SUBCOMMANDS:
  auto                    Plan a worklist from a brief, then sweep it through
                          the collection.
```

The Aleph and memory subcommands are the working surface. Each one takes a query or an alias and prints results to stdout; results from one command (`r5`, `d3491`, …) feed straight into the next. Aliases are stable across sessions on the same vault, so `r5` resolves to the same entity tomorrow. Responses are cached locally, so re-running the same call is free.

`sift <command> --help` lists flags for any subcommand.

## Sweeping a brief

The same tools can be driven by an LLM. `sift auto BRIEF` takes a brief — a list of topics, or freeform markdown instructions — and runs three phases:

1. **Plan** — an agent reads the brief and breaks it into a worklist of concrete leads (`leads.txt`).
2. **Sweep** — for each lead, a fresh, short-lived agent searches, reads, and pivots through the collection and writes up what it finds as a markdown segment, citing the source document for every claim. An agent that surfaces a new lead appends it with `sift queue`, so the sweep grows as it goes.
3. **Report** — a final agent stitches the segments into `report.md`, reviewing for overlap and contradictions as it goes.

```bash
cat > sanctions.md <<'EOF'
Search the leak for anything matching EU sanctions on Russia in force
before 2022 — dual-use exports under 833/2014, sovereign-debt and
securities restrictions, and dealings with designated banks
(Bank Rossiya, SMP Bank).
EOF

sift auto sanctions.md           # plan → sweep → report
```

Each lead gets its own bounded context, so the local model never bogs down dragging one investigation's history into the next — the reason the sweep beats a single long-running agent on a laptop. `leads.txt` is the run's state: open it mid-run and you see what's done (`✓`), what's pending, and what's been discovered. Re-running resumes where it left off.

Every claim in the report carries the alias of the document it came from, and `report.md` ends with a sources table linking each one straight back to its Aleph page — so the write-up stands on its own and every line is traceable.

The agent runs against either a local LLM (Qwen3 via [llama.cpp](https://github.com/ggml-org/llama.cpp), so only Aleph traffic leaves the machine) or any OpenAI-compatible hosted endpoint. Toggle with `sift backend local|hosted`. It's built on the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) harness; the bundled skill file documents the tool surface and a few Aleph quirks for the model.

## Quick start

```bash
brew install --cask data-desk-eco/tap/sift

sift init                              # vault, Aleph creds, LLM backend
sift search "acme corp"                # use the tools directly, or:
sift auto leads.txt                    # let the agent sweep a worklist
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
