"""Render an agent-written `report.md` into a human-readable
`report.html`, replacing every internal alias (`r1`, `r2`, …) with a
proper anchor that links to the entity's page on its Aleph server.

We walk the markdown-it AST rather than the raw source so substitutions
land on actual prose: alias-shaped tokens inside fenced code, inline
code, links, or HTML are left untouched."""

from __future__ import annotations

import html
import re
from dataclasses import dataclass
from pathlib import Path

from markdown_it import MarkdownIt
from markdown_it.token import Token

from .store import Store

ALIAS_RE = re.compile(r"\br(\d+)\b")


@dataclass
class AliasLink:
    alias: str
    entity_id: str
    schema: str | None
    name: str | None

    def url(self, server: str | None) -> str | None:
        if not server:
            return None
        # The web UI lives at the bare host; an `/api/2` suffix is for the
        # JSON API and won't render entity pages, so strip it if present.
        base = re.sub(r"/api/v?\d+/?$", "", server.rstrip("/"))
        if not base:
            return None
        return f"{base}/entities/{self.entity_id}"

    def title(self) -> str:
        bits = [self.entity_id]
        if self.schema:
            bits.append(self.schema)
        if self.name:
            bits.append(self.name)
        return " · ".join(bits)


def _lookup(store: Store, alias: str) -> AliasLink | None:
    row = store.conn.execute(
        """SELECT a.alias AS alias, a.entity_id AS entity_id,
                  e.schema AS schema, e.name AS name, e.caption AS caption
             FROM aliases a
             LEFT JOIN entities e ON e.id = a.entity_id
             WHERE a.alias = ?""",
        (alias,),
    ).fetchone()
    if row is None:
        return None
    return AliasLink(
        alias=row["alias"],
        entity_id=row["entity_id"],
        schema=row["schema"],
        name=row["name"] or row["caption"],
    )


@dataclass
class Counts:
    linked: int = 0
    unresolved: int = 0


def _substitute_text_token(child: Token, store: Store,
                           default_server: str | None,
                           counts: Counts) -> list[Token]:
    """Split a `text` token into a sequence of (text | html_inline) tokens,
    converting each `r\\d+` match into an `<a>` element. Tokens of any other
    type are returned untouched by the caller."""
    text = child.content
    pieces: list[Token] = []
    last = 0
    for m in ALIAS_RE.finditer(text):
        alias = m.group(0)
        link = _lookup(store, alias)
        if link is None:
            counts.unresolved += 1
            continue
        url = link.url(default_server)
        if url is None:
            counts.unresolved += 1
            continue
        if m.start() > last:
            pre = Token("text", "", 0)
            pre.content = text[last:m.start()]
            pieces.append(pre)
        anchor = Token("html_inline", "", 0)
        anchor.content = (
            f'<a href="{html.escape(url, quote=True)}" '
            f'title="{html.escape(link.title(), quote=True)}">'
            f'{html.escape(alias)}</a>'
        )
        pieces.append(anchor)
        counts.linked += 1
        last = m.end()
    if not pieces:
        return [child]
    if last < len(text):
        tail = Token("text", "", 0)
        tail.content = text[last:]
        pieces.append(tail)
    return pieces


def _walk_inline(token: Token, store: Store,
                 default_server: str | None,
                 counts: Counts) -> None:
    """Rewrite alias mentions inside an inline token, leaving structural
    children (links, code spans, html, etc.) alone — we only touch text
    nodes, so an alias inside `code` or a [link](url) stays as written."""
    new_children: list[Token] = []
    for child in token.children or []:
        if child.type == "text":
            new_children.extend(
                _substitute_text_token(child, store, default_server, counts)
            )
        else:
            new_children.append(child)
    token.children = new_children


HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{
    font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    max-width: 44rem; margin: 2.5rem auto; padding: 0 1.25rem;
  }}
  h1, h2, h3 {{ line-height: 1.25; }}
  pre, code {{ font-family: ui-monospace, "SF Mono", Menlo, monospace; }}
  pre {{ background: rgba(127,127,127,.12); padding: .75rem 1rem;
         border-radius: 6px; overflow-x: auto; }}
  code {{ background: rgba(127,127,127,.12); padding: .1em .35em;
          border-radius: 4px; }}
  pre code {{ background: transparent; padding: 0; }}
  a {{ color: #0a66c2; text-decoration: none; border-bottom: 1px solid currentColor; }}
  a:hover {{ filter: brightness(1.2); }}
  blockquote {{ margin: 1rem 0; padding: .25rem 1rem;
                border-left: 3px solid rgba(127,127,127,.4); color: inherit; }}
  table {{ border-collapse: collapse; }}
  th, td {{ padding: .35rem .6rem; border-bottom: 1px solid rgba(127,127,127,.3); }}
  hr {{ border: 0; border-top: 1px solid rgba(127,127,127,.3); margin: 2rem 0; }}
  .meta {{ color: rgba(127,127,127,.9); font-size: .9em; margin-bottom: 1.5rem; }}
</style>
</head>
<body>
<div class="meta">{meta}</div>
{body}
</body>
</html>
"""


def render_html(md_text: str, store: Store,
                default_server: str | None,
                title: str, meta: str) -> tuple[str, Counts]:
    md = MarkdownIt("commonmark", {"html": True}).enable("table")
    tokens = md.parse(md_text)
    counts = Counts()
    for tok in tokens:
        if tok.type == "inline":
            _walk_inline(tok, store, default_server, counts)
    body = md.renderer.render(tokens, md.options, {})
    return HTML_PAGE.format(
        title=html.escape(title),
        meta=html.escape(meta),
        body=body,
    ), counts


def export_report(src: Path, dst: Path, store: Store,
                  default_server: str | None) -> Counts:
    """Render `src` (markdown) to `dst` (HTML). Returns counts of aliases
    actually linked vs. unresolved — alias-shaped tokens inside code spans
    and fenced code aren't visited (they're left as raw text), so they
    don't contribute to either counter."""
    md_text = src.read_text()
    title = src.stem or "report"
    meta = f"rendered from {src.name}"
    if default_server:
        meta += f" · linking to {default_server}"
    page, counts = render_html(md_text, store, default_server,
                               title=title, meta=meta)
    dst.write_text(page)
    return counts
