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
  secrets.json            # ALEPH_URL, ALEPH_API_KEY, … (mode 0600)
  research/               # $ALEPH_SESSION_DIR — research products
    aleph.sqlite          # SHARED across sessions: aliases, entity cache,
                          # response cache. Same alias resolves to the same
                          # entity in every session on this vault.
    <session>/            # one subdir per logical session (notes, reports)
      report.md           # whatever you write — exports, timelines, etc.
```

`sift` auto-discovers credentials from a mounted vault when run from this directory, so you do not need to export `ALEPH_URL` / `ALEPH_API_KEY` yourself.

## Aliases

Aleph entity IDs are 64-char hashes. The CLI assigns short aliases (`r1`, `r2`, …) to every entity that appears in any tool output, so you can refer to them in subsequent calls. Use the alias in `read alias=r5`, `expand alias=r5`, etc. The alias table is stored in `$ALEPH_SESSION_DIR/aleph.sqlite` and is shared across every session on the same vault — `r5` in one investigation resolves to the same entity in the next.

## Research tools

All commands take `key=value` style arguments (also `--key value` works).

### `search`

Query the collection for hits.

```
sift search query="<text>" [type=<emails|docs|web|people|orgs|any>] [collection=<id>]
                              [emitter=<alias>] [recipient=<alias>] [mentions=<alias>]
                              [date_from=YYYY-MM-DD] [date_to=YYYY-MM-DD]
                              [limit=10] [offset=0] [sort=date]
```

- `type` defaults to `any` (Document + Email + HyperText). Use `people`/`orgs` to search the party graph, not documents.
- `emitter`/`recipient` accept an alias of a Person or Organization. Combine to filter "emails from X to Y".
- `mentions=<alias>` filters to documents Aleph has linked to a specific entity.
- `date_from`/`date_to` filter on `properties.dates` (any date Aleph extracted).

Each result is shown with its alias on the left. Page forward with `offset=`.

### `read`

Pull the full content of an entity (document body, email body + headers, party profile).

```
sift read alias=r5 [full=true] [raw=true]
```

- `full=true` — don't truncate the body (default truncates at ~1500 chars).
- `raw=true` — dump the full FtM JSON blob (for debugging).

`read` short-circuits to the local cache when we already have the body from a prior search/expand response.

### `expand`

Show every entity Aleph has linked to this one via FtM property refs (emitters, recipients, mentions, parent, owner, attachment, …), grouped by property.

```
sift expand alias=r5 [property=<name>] [limit=20]
```

- `property=` narrows to one relation (e.g. `property=mentions`).
- For party entities (Person, Organization, …), `expand` returns reverse-property *counts* only — Aleph won't enumerate "all emails received by this party" through `/expand`. The CLI tells you to use `search recipient=r5` instead.

### `browse`

Filesystem-style: show this entity's parent folder and every sibling. Works on any entity that has a `parent` property — emails inside a mailbox, files inside a folder, attachments inside an email.

```
sift browse alias=r5 [limit=30]
```

Annotates subfolders with descendant counts (so you can see where the volume lives before drilling in).

### `tree`

Render a multi-level ASCII tree of a folder's subtree (or of a collection's roots).

```
sift tree alias=r5 [depth=3] [max_siblings=20]
sift tree collection=<id> [max_siblings=20]
```

Only works on folder-like schemas (Folder, Package, Workbook, Directory).

### `similar`

Aleph-extracted name-variant candidates for a party entity (Person / Organization / Company / PublicBody / LegalEntity).

```
sift similar alias=r5 [limit=10]
```

Returns scored candidates that may be the same real-world party with a different spelling.

### `hubs`

Faceted view: for entities matching a query, what are the top emitters / recipients / mentioned people / mentioned companies?

```
sift hubs query="<text>" [collection=<id>] [schema=Email] [limit=10]
```

Use this to find central parties on a topic before drilling into individual messages. Mentioned-people / mentioned-companies are returned as text strings — feed them back into `search` as a free-text query.

### `sources`

List Aleph collections visible to your API key.

```
sift sources [grep=<term>] [limit=50]
```

## Aleph quirks worth knowing

- **10,000 hit cap**: Aleph caps `offset + limit` at 10k. Beyond that, results are unreachable through pagination — narrow by collection or date range.
- **Fuzzy queries time out** on large collections. Stick to literal terms.
- Responses are cached locally (keyed on the full argument set); a `(cached)` tag appears in the header when you see one. Pass `no_cache=true` to force a refetch.
