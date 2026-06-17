---
name: sift
description: Investigate a subject in an Aleph or OpenAleph collection — search and read documents, emails, and entities, follow extracted links between people/orgs/documents, and record what you find as FollowTheMoney entities. Tools chain naturally — search → read → expand → search again — and the encrypted vault keeps API keys and findings at rest.
---

# sift

Investigate inside an [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/) collection. The CLI is `sift` (already on your PATH). Credentials and your findings stay in an AES-256 encrypted vault.

## Where things live

The vault mounts at `$VAULT_MOUNT`. Under `research/` is the shared `aleph.sqlite` (alias + entity cache, shared across every session on the vault) and one directory per run holding:

- `topics.txt` — the worklist of leads for this run
- `findings.db` — your FtM entities (`$SIFT_FINDINGS_DB`), shared across the run
- `digest.md` — periodic consolidation, prepended to your prompt
- `report.md` — the final write-up

Aleph creds are already in `$ALEPH_URL` / `$ALEPH_API_KEY` — never open `secrets.json` yourself. You are one session in a sweep: you get a single lead (in your first message); investigate it and record what you find. The setup/run commands (`init`, `vault`, `backend`, `project`, `auto`) are the operator's — never call them.

## Aliases

Every Aleph entity gets a short alias (`r1`, `r2`, …) on first sight, stored in `aleph.sqlite` and stable across every session on the vault — `r5` resolves to the same entity tomorrow. Use the alias as the positional argument: `sift read r5`, `sift expand r5`. Your own findings get `f1`, `f2`, ….

## One sift call at a time

Issue sift commands serially, never in parallel. Every call writes the shared `aleph.sqlite` (aliases, response cache, edges); two racing writes fail one with `UNIQUE constraint failed: aliases.n`. Wait for each call to return. If you hit that error anyway, don't loop-retry — use the raw 64-char id printed alongside the alias, or pick up another thread; it assigns cleanly on the next call.

## Tools

Flags are POSIX-style (`sift <cmd> --help` for the full list); short forms `-l`/`--limit`, `-f`/`--full`, `-r`/`--raw`, `-o`/`--offset`. The query or alias is positional.

**Search & read**
- `search "<text>" [--type emails|docs|people|orgs|any] [--collection <id>] [--emitter|--recipient|--mentions <alias>] [--date-from|--date-to YYYY-MM-DD]` — hits, each with an alias; page with `--offset`.
- `read <alias> [-f] [-r]` — full content (`-f` un-truncates the body). Also lists any findings that cite this entity.

**Pivot**
- `expand <alias> [--property <name>]` — entities linked via FtM refs. For a party, use `search --recipient <alias>` (expand only returns counts).
- `similar <alias>` — name-variant candidates for a party.
- `hubs "<text>" [--schema Email]` — top emitters / recipients / mentions on a topic.
- `browse <alias>` / `tree <alias>|--collection <id>` — folder parent+siblings / ASCII subtree.
- `neighbours <alias>` — edges sift has cached for an entity (run `expand` first to populate).

**Local cache (free, no Aleph round-trip)**: `recall` (what's already cached), `sql "<SELECT …>"` (read-only), `cache stats`, `sources [<grep>]`. `sift time` shows remaining time and a pacing hint when the session is timed.

## Recording findings

Record every structured fact as a FollowTheMoney entity — the schema Aleph itself uses, so findings export straight back in.

```
sift entity schemas [<Schema>]            # list schemas / one schema's props (refs marked)
sift entity create <Schema> -p k=v …      # repeatable props; or --json '<ftm>'
sift entity list [--schema X] | show <alias> | edit <alias> -p k=v | delete <alias>
```

Example — a payment between two parties you read in `r512`:

```
sift entity create Company -p name="Acme Holdings" -p jurisdiction=cy
sift entity create Person  -p firstName=John -p lastName=Doe
sift entity create Payment -p payer=f1 -p beneficiary=f2 -p amount=50000 -p currency=USD --source r512
```

- **Reference entities by alias** (`f1`, `r512`, or a raw id) in ref-typed properties — `sift entity schemas <Schema>` marks which properties are refs. This is what keeps the graph connected.
- **Cite the source** with `--source <alias>`; `sift read <alias>` then surfaces your findings inline. Back a load-bearing fact with a short verbatim quote (≤30 words) in the entity's `description`.
- **Pick the right schema.** Relationships (Payment, Ownership, Directorship, Membership, UnknownLink, …) are edges between two parties; the rest are things (Person, Company, BankAccount, …). Unknown property kept with a warning; unknown schema rejected.
- Surfaced another lead worth its own pass? `sift queue "<lead>"` — a later session picks it up.

## Aleph quirks

- **10k cap**: Aleph caps `offset + limit` at 10,000. Narrow by collection or date beyond that.
- **Fuzzy queries time out** on large collections — stick to literal terms.
- Responses cache locally (a `(cached)` tag shows in the header); pass `--no-cache` to refetch.
