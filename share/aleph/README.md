# aleph (skill)

A drop-in agent skill for [Aleph](https://aleph.occrp.org) — search documents
and emails, read full bodies, follow Aleph-extracted links between entities,
browse folders. Includes an encrypted-sparseimage vault for credentials and
research products.

## What's in this folder

```
aleph/
  SKILL.md          ← entry point with frontmatter (`name: aleph`)
  aleph             ← the CLI (single file; uv inline-script self-installs deps)
  bin/
    touchid.swift   ← Touch ID prompt source
    touchid         ← compiled by the CLI on first vault unlock (gitignore it)
  README.md         ← this file
```

That's the entire skill. Drop the folder anywhere and it works.

## Installing

### As a project-local skill

```sh
cp -R aleph/ /path/to/your-project/aleph/
cd /path/to/your-project
./aleph/aleph vault init                     # creates .vault.sparseimage in cwd
./aleph/aleph vault set ALEPH_URL https://aleph.occrp.org
./aleph/aleph vault set ALEPH_API_KEY <key>
./aleph/aleph search query="…"               # auto-discovers the vault
```

### As a global skill (used from any project)

```sh
cp -R aleph/ ~/.pi/agent/skills/aleph/        # or whatever your harness uses
# then in any project:
cd ~/some-project
~/.pi/agent/skills/aleph/aleph vault init     # vault lands in cwd
```

### Wired into pi (or any agent harness)

Pass the skill folder path:

```sh
pi --skill /path/to/aleph "investigate <subject>"
```

The agent reads `SKILL.md` for the tool reference and shells out to the CLI.

## How it stays self-contained

The CLI uses two distinct directory roots:

| Root | What it is | How it's found |
|------|------------|----------------|
| **skill dir** | Where this CLI and `bin/touchid.swift` live | `Path(__file__).resolve().parent` — stable, follows the script |
| **project dir** | Where `.vault.sparseimage` lives | Walk up from cwd; `$ALEPH_PROJECT_DIR` overrides |

So one skill folder serves any number of projects: each project that runs `aleph vault init` gets its own `.vault.sparseimage` at its own root, with its own random passphrase under `~/.aleph/<project-hash>.passphrase`. The skill doesn't know or care.

## Requirements

- macOS (Touch ID + `hdiutil` sparseimage)
- Xcode Command Line Tools (`swiftc` for the Touch ID helper) — the CLI compiles `bin/touchid.swift` on first vault unlock.
- [uv](https://docs.astral.sh/uv/) — the CLI is a uv inline-script (`#!/usr/bin/env -S uv run --script`). Installs `requests` automatically on first run; no setup step.

## Tools

See [`SKILL.md`](./SKILL.md) for the full reference. Quick list:

| Command                       | What                                                                  |
|-------------------------------|-----------------------------------------------------------------------|
| `aleph search …`              | Free-text + property-filtered search of a collection.                 |
| `aleph read alias=r5`         | Pull the full body of an entity.                                      |
| `aleph expand alias=r5`       | All entities Aleph has linked to this one, grouped by property.       |
| `aleph browse alias=r5`       | Show this entity's parent folder and siblings.                        |
| `aleph tree alias=r5`         | Multi-level ASCII tree of a folder subtree.                           |
| `aleph similar alias=r5`      | Aleph-extracted name-variant candidates for a party.                  |
| `aleph hubs query=…`          | Faceted top emitters / recipients / mentions for a query.             |
| `aleph sources`               | List available collections.                                           |
| `aleph vault init`            | Create the sparseimage in cwd, mount it, generate passphrase.         |
| `aleph vault unlock` / `lock` | Mount / detach (Touch ID gates unlock).                               |
| `aleph vault status`          | mounted at / locked / uninitialised.                                  |
| `aleph vault env`             | Print `export …` lines for the agent / shell.                         |
| `aleph vault exec <cmd …>`    | Auto-unlock, exec cmd with vault env populated.                       |
| `aleph vault set/get/list`    | Manage `secrets.json` inside the vault (mode 0600).                   |

## Layout when the vault is mounted

```
/Volumes/vault-<hash>/
  secrets.json          # ALEPH_URL, ALEPH_API_KEY, … (mode 0600)
  research/             # ALEPH_SESSION_DIR — agent writes here
    aleph.sqlite        # SHARED: aliases (r1, r2, …), entity blobs, response
                        # cache. Persists across every session on this vault.
    <session>/          # one subdir per logical session
      …                 # notes, timelines, report.md, exports
```

Override the SQLite location with `ALEPH_DB_PATH` if you want a per-session
DB (e.g. for isolated experiments).

## Threat model

- **Protects:** stolen sparseimage file, attacker without an active session on your account.
- **Does not protect:** attacker with access to your logged-in macOS user (the passphrase file lives in `~/.aleph/`).

Same model as Aileph's vault.
