---
name: sift
description: Investigate a subject in an Aleph or OpenAleph collection — search and read documents, emails, and entities, follow extracted links between people/orgs/documents, browse folder trees, find name variants. Tools chain naturally — search → read → expand → search again — and the encrypted vault keeps API keys and research products at rest.
---

# sift

Investigate a subject inside an [Aleph](https://aleph.occrp.org) or [OpenAleph](https://openaleph.org/) collection and keep credentials + research products in an AES-256 encrypted volume. The CLI is `sift` (already on your PATH).

## Where things live

When the vault is unlocked it mounts at `$VAULT_MOUNT` (printed by `sift vault status`). Inside:

```
$VAULT_MOUNT/
  research/               # $ALEPH_SESSION_DIR — research products
    aleph.sqlite          # SHARED across sessions: aliases, entity cache,
                          # response cache. Same alias resolves to the same
                          # entity in every session on this vault.
    <session>/            # one subdir per logical session (notes, reports)
      report.md           # whatever you write — exports, timelines, etc.
      findings.db         # $SIFT_FINDINGS_DB — your FtM findings, via
                          # `sift entity` (per-session, never shared)
      auto.log            # filtered live log of the agent run
      pi.stderr.log       # raw pi process stderr
      .pi-sessions/       # pi's own conversation state
```

API keys live in the encrypted vault (`<vault>/secrets.json`). `sift auto` injects `ALEPH_URL` and `ALEPH_API_KEY` into your environment automatically, so you do not need to read the file yourself.

## Off-limits commands

The sift CLI also exposes setup and run-management commands (`sift init`, `sift vault`, `sift backend`, `sift project`, `sift auto`, `sift lead`, `sift status`, `sift logs`, `sift stop`). **These are for the human operator, not for you.** Never invoke them — you'll either prompt the user for the vault passphrase, fork another agent, or stop your own run.

Aleph creds are already in your environment as `$ALEPH_URL` / `$ALEPH_API_KEY`. Don't try to open `<vault>/secrets.json` yourself — the file is intentionally human-only.

If you need information about the current run (deadline, session dir, available aliases), or about prior investigations on the same vault, use the agent-facing commands documented below: `sift time`, `sift recall`, `sift sql`, `sift cache stats`, `sift report`.

## Aliases

Aleph entity IDs are 64-char hashes. The CLI assigns short aliases (`r1`, `r2`, …) to every entity that appears in any tool output, so you can refer to them in subsequent calls. Use the alias as the positional argument: `sift read r5`, `sift expand r5`, etc. The alias table is stored in `$ALEPH_SESSION_DIR/aleph.sqlite` and is shared across every session on the same vault — `r5` in one investigation resolves to the same entity in the next.

## One sift call at a time

Issue sift commands serially, never in parallel batches. Every call writes into the same `aleph.sqlite` (alias assignments, response cache, edge cache); two writes racing will fail one of them with `UNIQUE constraint failed: aliases.n` or a similar SQLite error. Wait for each sift call to return before issuing the next.

If you see that exact error anyway, do not retry the same command in a loop — the alias slot is contested, not broken. Move on with the raw entity ID (the 64-char hash printed alongside the alias) or pick up a different thread of the investigation; the alias will assign cleanly on the next sequential call. Surface persistent failures to the user instead of mashing retry.

## Research tools

All commands take standard POSIX-style flags: `--limit 20`, `--collection 3843`, `--no-cache`. Short flags `-l`, `-f`, `-r`, `-o` map to `--limit`, `--full`, `--raw`, `--offset`. The natural argument (a query or alias) is positional, so `sift read r5` and `sift search "acme corp"` work without naming it. `sift <cmd> --help` lists every flag for that command.

### `search`

Query the collection for hits.

```
sift search "<text>" [--type emails|docs|web|people|orgs|any] [--collection <id>]
                     [--emitter <alias>] [--recipient <alias>] [--mentions <alias>]
                     [--date-from YYYY-MM-DD] [--date-to YYYY-MM-DD]
                     [--limit 10] [--offset 0] [--sort date]
```

- `--type` defaults to `any` (Document + Email + HyperText). Use `people`/`orgs` to search the party graph, not documents.
- `--emitter`/`--recipient` accept an alias of a Person or Organization. Combine to filter "emails from X to Y".
- `--mentions <alias>` filters to documents Aleph has linked to a specific entity.
- `--date-from`/`--date-to` filter on `properties.dates` (any date Aleph extracted).

Each result is shown with its alias on the left. Page forward with `--offset`.

### `read`

Pull the full content of an entity (document body, email body + headers, party profile).

```
sift read <alias> [-f|--full] [-r|--raw]
```

- `-f`/`--full` — don't truncate the body (default truncates at ~1500 chars).
- `-r`/`--raw` — dump the full FtM JSON blob (for debugging).

`read` short-circuits to the local cache when we already have the body from a prior search/expand response.

### `expand`

Show every entity Aleph has linked to this one via FtM property refs (emitters, recipients, mentions, parent, owner, attachment, …), grouped by property.

```
sift expand <alias> [--property <name>] [--limit 20]
```

- `--property` narrows to one relation (e.g. `--property mentions`).
- For party entities (Person, Organization, …), `expand` returns reverse-property *counts* only — Aleph won't enumerate "all emails received by this party" through `/expand`. The CLI tells you to use `sift search --recipient r5` instead.

### `browse`

Filesystem-style: show this entity's parent folder and every sibling. Works on any entity that has a `parent` property — emails inside a mailbox, files inside a folder, attachments inside an email.

```
sift browse <alias> [--limit 30]
```

Annotates subfolders with descendant counts (so you can see where the volume lives before drilling in).

### `tree`

Render a multi-level ASCII tree of a folder's subtree (or of a collection's roots).

```
sift tree <alias> [--depth 3] [--max-siblings 20]
sift tree --collection <id> [--max-siblings 20]
```

Only works on folder-like schemas (Folder, Package, Workbook, Directory).

### `similar`

Aleph-extracted name-variant candidates for a party entity (Person / Organization / Company / PublicBody / LegalEntity).

```
sift similar <alias> [--limit 10]
```

Returns scored candidates that may be the same real-world party with a different spelling.

### `hubs`

Faceted view: for entities matching a query, what are the top emitters / recipients / mentioned people / mentioned companies?

```
sift hubs "<text>" [--collection <id>] [--schema Email] [--limit 10]
```

Use this to find central parties on a topic before drilling into individual messages. Mentioned-people / mentioned-companies are returned as text strings — feed them back into `search` as a free-text query.

### `sources`

List Aleph collections visible to your API key.

```
sift sources [<grep-term>] [--limit 50]
```

## Local cache tools

These commands read against the local SQLite cache only — no Aleph round-trip, so they're free to call freely.

### `recall`

Summarise what's already in the cache for this vault: schema mix, top-degree nodes (entities with the most cached relations), and what was touched most recently.

```
sift recall [--collection <id>] [--schema <S>] [--limit 15]
```

Use this at the start of a session to see what prior investigations have already pulled in — same alias table, same entities.

### `neighbours`

Show every edge sift has cached for an entity, grouped by FtM property. Built from data already returned by `read` / `expand` / `search`, so coverage is partial — but for entities you've already explored it lets you re-walk the graph without spending API calls.

```
sift neighbours <alias> [--direction out|in|both] [--property <name>] [--limit 50]
```

If neighbours returns "(no cached edges)", run `sift expand <alias>` first to populate them.

### `sql`

Read-only SQL against the cache DB. The connection is opened in `mode=ro`, so writes are rejected even if you ask for them.

```
sift sql "SELECT alias, schema, name FROM aliases JOIN entities ON entities.id=aliases.entity_id ORDER BY n DESC LIMIT 10"
```

#### Cache schema

```
entities(id, schema, caption, name, properties JSON, collection_id, server,
         has_full_body, first_seen, updated_at)
aliases(alias, n, entity_id, assigned_at)
edges(src_id, prop, dst_id, first_seen)
cache(key, value JSON, set_at)
```

Useful joins: `aliases.entity_id = entities.id`; `edges.src_id`/`edges.dst_id` reference `entities.id`. `properties` is JSON — use SQLite's `json_extract(properties, '$.subject[0]')` for nested fields.

### `cache stats`

```
sift cache stats
```

Reports DB size, row counts per table, and the age range of cached responses. Useful when you want to know whether `recall` is likely to find anything before you call it.

### `report`

Read a prior lead's `report.md` to consolidate findings across investigations on the same vault. The vault stores one lead per directory under `$ALEPH_SESSION_DIR`, each with its own `report.md`; this command cats the markdown to stdout so you can search it inline.

```
sift report --list                # leads with a report.md (sorted by recency)
sift report <lead>                # cat that lead's report.md
sift report                       # cat the current lead's report.md
```

Use `--list` first to see what's available. Lead names are the directory names that appear in `$ALEPH_SESSION_DIR/<lead>/`. Validation rejects path traversal, so you can't escape the research directory.

## Recording structured findings

When you extract a structured fact worth keeping — a company, a person, a payment, an ownership link — record it as a [FollowTheMoney](https://followthemoney.tech) entity with `sift entity`, the same schema Aleph itself uses. Findings get their own aliases (`f1`, `f2`, …), so the next leg can browse them without re-reading sources, and they export straight back into Aleph.

```
sift entity schemas                  # list FtM schemas
sift entity schemas Payment          # one schema's properties (refs marked)
sift entity create <Schema> -p k=v   # create from key=value props (repeatable)
sift entity create --json '<ftm>'    # or pass a full FtM entity as JSON
sift entity list [--schema X]        # browse findings (--json for raw FtM)
sift entity show f3 [--json]         # one finding in full
sift entity edit f3 -p amount=75000  # set/--remove props in place
sift entity delete f3                # remove (blocked if still referenced)
```

Example — a payment between two parties you read about in `r512`:

```
sift entity create Company -p name="Acme Holdings" -p jurisdiction=cy
sift entity create Person  -p firstName=John -p lastName=Doe
sift entity create Payment -p payer=f1 -p beneficiary=f2 \
  -p amount=50000 -p currency=USD -p date=2024-03-12 --source r512
```

Conventions:

- **Reference other entities by alias.** Ref-typed properties (`payer`, `owner`, `member`, `organization`, …) take a findings alias (`f1`), an Aleph alias (`r512`), or a raw id — sift resolves them so the graph stays connected. `sift entity schemas <Schema>` marks which properties are refs.
- **Cite the source.** `--source r512` records where the fact came from; `sift read r512` then shows which findings cite it, so a later leg sees your prior judgement inline.
- **Pick the right schema.** Relationships (Payment, Ownership, Directorship, Membership, …) are edges between two parties; the rest are things (Person, Company, BankAccount, …). Unknown schemas are rejected; an unknown property is kept with a warning so a registry gap never blocks you.
- This is for *structured* facts. Keep narrative and the verbatim quotes that back load-bearing claims in `report.md`.

## Pacing

If the session has a deadline, the system prompt will say so. Run `sift time` every few tool calls to see remaining time and a phase hint:

```
sift time
```

Phases: **explore** (>50% left, push deep), **deepen** (25–50%, no new directions), **consolidate** (10–25%, tie up and start drafting), **wrap-up** (<10%, write report.md and stop). Outside a timed session, `sift time` reports no deadline — pace normally.

## Aleph quirks worth knowing

- **10,000 hit cap**: Aleph caps `offset + limit` at 10k. Beyond that, results are unreachable through pagination — narrow by collection or date range.
- **Fuzzy queries time out** on large collections. Stick to literal terms.
- Responses are cached locally (keyed on the full argument set); a `(cached)` tag appears in the header when you see one. Pass `--no-cache` to force a refetch.
