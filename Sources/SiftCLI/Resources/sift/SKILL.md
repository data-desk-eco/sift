---
name: sift
description: Investigate a subject in an Aleph or OpenAleph collection — search and read documents, emails, and entities, follow extracted links between people/orgs/documents, and write up what you find with citations back to the source. Tools chain naturally — search → read → expand → search again — and the encrypted vault keeps API keys and findings at rest.
---

# sift

Investigate inside an [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/) collection. The CLI is `sift` (already on your PATH). Credentials and your findings stay in an AES-256 encrypted vault.

## Where things live

The vault mounts at `$VAULT_MOUNT`. Under `research/` is the shared `aleph.sqlite` (alias + entity cache, shared across every session on the vault) and one directory per run holding:

- `leads.txt` — the worklist of leads for this run
- `segments/` — one markdown file per lead; you write yours up as you go (path in `$SIFT_SEGMENT`)
- `report.md` — the final write-up, stitched from the segments

You're already running in this run directory, and every path sift needs is in the environment — just call `sift …` directly; never `cd`. Aleph creds are already in `$ALEPH_URL` / `$ALEPH_API_KEY` — never open `secrets.json` yourself. You are one session in a sweep: you get a single lead (in your first message); investigate it and write up what you find. The setup/run commands (`init`, `vault`, `backend`, `project`, `auto`) are the operator's — never call them.

## Aliases

Every Aleph entity gets a short alias (`r1`, `r2`, …) on first sight, stored in `aleph.sqlite` and stable across every session on the vault — `r5` resolves to the same entity tomorrow. Use the alias as the positional argument: `sift read r5`, `sift expand r5`. Cite these aliases in your write-up so every claim traces back to a document.

## How to work

Issue **one sift call at a time** — never in parallel. Every call writes the shared `aleph.sqlite` (alias assignments, response cache), and two racing writes fail one with `UNIQUE constraint failed: aliases.n`. If you hit that, don't loop-retry — use the raw 64-char id printed beside the alias, or pick up another thread, and it assigns cleanly on the next call.

Work the loop **search broad → read selectively → write up → pivot**, keeping your context lean as you go:

- **Search** wide with cheap, literal queries and skim the result table — each row carries an alias. You're deciding *which* documents to open, so keep `--limit` small (10–20); you don't need every hit here.
- **Read** only the aliases that look load-bearing. Plain `sift read <alias>` truncates the body to ~1500 chars, usually enough to judge relevance — spend `-f` (full text) only on a document you've decided matters. Full bodies are by far the biggest drain on your context.
- **Write up** what a document establishes the moment you confirm it (see *Writing it up*), before your next search — never batched at the end.
- **Pivot** with `expand` / `similar` / `hubs` / `browse` to follow the links, then search again.

Flags belong to specific commands — there are no universal ones. `--limit` / `--offset` page the list-producing commands (`search`, `expand`, `hubs`, `tree`, `recall`); `--full` / `--raw` are `read` only. `sift <cmd> --help` is authoritative.

## Tools

**Search & read**
- `search "<text>" [--type emails|docs|people|orgs|any] [--collection <id>] [--emitter|--recipient|--mentions <alias>] [--date-from|--date-to YYYY-MM-DD] [--limit N] [--offset N]` — hits, each with an alias.
- `read <alias> [-f|--full] [-r|--raw] [--limit N]` — entity content for one alias (not a search — no result count). Body is truncated unless `-f`; `--limit N` caps it to N characters instead. `-r` dumps raw FtM JSON. The header prints the entity's Aleph url, for linking in your write-up.
- `download <alias>` — save the underlying file (the docx/pdf/xlsx behind a document hit) to `<research>/files/` and print its local path. `read` only shows Aleph's extracted text; reach for `download` when the layout, embedded tables, or a non-text attachment matter, then inspect the saved file with plain bash (`textutil`, `pdftotext`, `unzip -l`, `file`, `strings`). Parties, folders, and web pages have no file and can't be downloaded.

**Pivot**
- `expand <alias> [--property <name>]` — entities linked via FtM refs. For a party, use `search --recipient <alias>` (expand only returns counts).
- `similar <alias>` — name-variant candidates for a party.
- `hubs "<text>" [--schema Email]` — top emitters / recipients / mentions on a topic.
- `browse <alias>` / `tree <alias>|--collection <id>` — folder parent+siblings / ASCII subtree.
- `neighbours <alias>` — edges sift has cached for an entity (run `expand` first to populate).

**Local cache (free, no Aleph round-trip)**: `recall` (what's already cached), `sql "<SELECT …>"` (read-only), `cache stats`, `sources [<grep>]`. `sift time` shows remaining time and a pacing hint when the session is timed.

## Writing it up

Record findings with `sift note "<finding>"` — one call per fact, which appends it to the markdown segment at `$SIFT_SEGMENT`, your share of the final report. Don't hand-edit the file: `sift note` is a single append, so nothing is lost if your session ends early. Lead with `sift note "## <lead>"` to title your section, then add to it as you go:

- **Neutral, wire-service prose.** State what the documents show; don't editorialise or hype. For structured data (parties, dates, amounts), pass a whole markdown table as one note.
- **Cite the source alias inline** (`r512`) for every load-bearing claim, so each is traceable. `sift read <alias>` prints the entity's Aleph `url:` — use it for `[open](<url>)` links where a reader will want the source.
- **Note as you go, never batched at the end.** A fact only in your context is lost when the session ends.
- Surfaced another lead worth its own pass? `sift queue "<lead>"` — a later session picks it up. It confirms each add (or says it's already queued); `sift queue --list` shows the worklist. Queue each lead once and trust it — no need to re-add or check the file.

## Aleph quirks

- **10k cap**: Aleph caps `offset + limit` at 10,000. Narrow by collection or date beyond that.
- **Fuzzy queries time out** on large collections — stick to literal terms.
- Responses cache locally (a `(cached)` tag shows in the header); pass `--no-cache` to refetch.
