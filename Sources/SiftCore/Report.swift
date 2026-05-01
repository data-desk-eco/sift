import Foundation
import Markdown

/// Render an agent-written `report.md` into a human-readable
/// `report.html`, replacing every internal alias (`r1`, `r2`, …) with
/// an anchor that links to the entity's page on its Aleph server.
///
/// We render Markdown with swift-markdown then post-process the HTML,
/// skipping `<pre>` and inline `<code>` regions so alias-shaped tokens
/// inside code blocks stay as written.
public enum Report {

    public struct Counts: Sendable {
        public var linked: Int
        public var unresolved: Int
        public init(linked: Int = 0, unresolved: Int = 0) {
            self.linked = linked; self.unresolved = unresolved
        }
    }

    public struct AliasLink: Sendable {
        public let alias: String
        public let entityId: String
        public let schema: String?
        public let name: String?

        public func url(server: String?) -> String? {
            guard let server, !server.isEmpty else { return nil }
            // The web UI lives at the bare host; an `/api/2` suffix is for
            // the JSON API and won't render entity pages — strip it.
            var base = server.hasSuffix("/") ? String(server.dropLast()) : server
            if let r = base.range(of: #"/api/v?\d+/?$"#, options: .regularExpression) {
                base = String(base[..<r.lowerBound])
            }
            if base.isEmpty { return nil }
            return "\(base)/entities/\(entityId)"
        }

        public var title: String {
            var bits = [entityId]
            if let s = schema, !s.isEmpty { bits.append(s) }
            if let n = name, !n.isEmpty { bits.append(n) }
            return bits.joined(separator: " · ")
        }
    }

    /// Render `src` (markdown) to `dst` (HTML). Returns counts of
    /// aliases actually linked vs. unresolved.
    @discardableResult
    public static func export(
        src: URL, dst: URL, store: Store, defaultServer: String?
    ) throws -> Counts {
        let mdText = try String(contentsOf: src, encoding: .utf8)
        let title = src.deletingPathExtension().lastPathComponent
        var meta = "rendered from \(src.lastPathComponent)"
        if let server = defaultServer, !server.isEmpty {
            meta += " · linking to \(server)"
        }
        let result = renderHTML(
            markdown: mdText, store: store,
            defaultServer: defaultServer, title: title, meta: meta
        )
        try result.html.write(to: dst, atomically: true, encoding: .utf8)
        return result.counts
    }

    public struct RenderResult: Sendable {
        public let html: String
        public let counts: Counts
    }

    public static func renderHTML(
        markdown: String, store: Store,
        defaultServer: String?, title: String, meta: String
    ) -> RenderResult {
        let document = Document(parsing: markdown,
                                options: [.parseBlockDirectives, .parseSymbolLinks])
        var formatter = HTMLFormatter()
        formatter.visit(document)
        let body = formatter.result

        var counts = Counts()
        let linkedBody = substituteAliases(
            html: body, store: store,
            defaultServer: defaultServer, counts: &counts
        )
        let page = pageHTML(title: title, meta: meta, body: linkedBody)
        return RenderResult(html: page, counts: counts)
    }

    // MARK: - Alias substitution

    static let aliasRegex: NSRegularExpression = {
        // word boundaries on both sides
        try! NSRegularExpression(pattern: #"\br(\d+)\b"#)
    }()

    static func substituteAliases(
        html: String, store: Store,
        defaultServer: String?, counts: inout Counts
    ) -> String {
        var output = ""
        output.reserveCapacity(html.count + 256)
        let scalars = Array(html.unicodeScalars)
        var i = 0
        var inPreOrCode = 0  // depth counter for <pre>/<code>

        while i < scalars.count {
            let ch = scalars[i]
            if ch == "<" {
                // Read the whole tag.
                let start = i
                while i < scalars.count, scalars[i] != ">" { i += 1 }
                if i < scalars.count { i += 1 } // include the closing '>'
                let tag = String(String.UnicodeScalarView(scalars[start..<i]))
                if isOpenTag(tag, named: "pre") || isOpenTag(tag, named: "code") {
                    inPreOrCode += 1
                } else if isCloseTag(tag, named: "pre") || isCloseTag(tag, named: "code") {
                    inPreOrCode = max(0, inPreOrCode - 1)
                }
                output.append(tag)
                continue
            }
            // Read one text segment (until the next '<').
            let start = i
            while i < scalars.count, scalars[i] != "<" { i += 1 }
            let text = String(String.UnicodeScalarView(scalars[start..<i]))
            if inPreOrCode > 0 {
                output.append(text)
            } else {
                output.append(rewriteAliases(text: text, store: store,
                                              defaultServer: defaultServer, counts: &counts))
            }
        }
        return output
    }

    private static func rewriteAliases(
        text: String, store: Store,
        defaultServer: String?, counts: inout Counts
    ) -> String {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = aliasRegex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for m in matches {
            let r = m.range
            let alias = nsText.substring(with: r)
            guard let link = lookup(store: store, alias: alias),
                  let url = link.url(server: defaultServer)
            else {
                counts.unresolved += 1
                continue
            }
            if r.location > cursor {
                out += nsText.substring(with: NSRange(location: cursor, length: r.location - cursor))
            }
            let escapedURL = htmlEscape(url, attribute: true)
            let escapedTitle = htmlEscape(link.title, attribute: true)
            let escapedAlias = htmlEscape(alias)
            out += "<a href=\"\(escapedURL)\" title=\"\(escapedTitle)\">\(escapedAlias)</a>"
            counts.linked += 1
            cursor = r.location + r.length
        }
        if cursor < nsText.length {
            out += nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
        }
        return out
    }

    private static func lookup(store: Store, alias: String) -> AliasLink? {
        let sql = """
            SELECT a.alias AS alias, a.entity_id AS entity_id,
                   e.schema AS schema, e.name AS name, e.caption AS caption
              FROM aliases a
              LEFT JOIN entities e ON e.id = a.entity_id
             WHERE a.alias = ?
            """
        guard let row = (try? queryRows(store: store, sql: sql, binds: [alias])).flatMap({ $0.first })
        else { return nil }
        let entityId = row[1] ?? ""
        guard !entityId.isEmpty else { return nil }
        return AliasLink(
            alias: row[0] ?? alias,
            entityId: entityId,
            schema: row[2],
            name: row[3] ?? row[4]
        )
    }

    private static func isOpenTag(_ tag: String, named name: String) -> Bool {
        // <name> or <name attr=...>
        let pattern = "^<\(name)([\\s>]|/>)"
        return tag.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isCloseTag(_ tag: String, named name: String) -> Bool {
        let pattern = "^</\(name)\\s*>"
        return tag.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func htmlEscape(_ raw: String, attribute: Bool = false) -> String {
        var s = raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            s = s.replacingOccurrences(of: "\"", with: "&quot;")
        }
        return s
    }

    private static func pageHTML(title: String, meta: String, body: String) -> String {
        let escTitle = htmlEscape(title)
        let escMeta = htmlEscape(meta)
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <title>\(escTitle)</title>
            <style>
              :root { color-scheme: light dark; }
              body {
                font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                max-width: 44rem; margin: 2.5rem auto; padding: 0 1.25rem;
              }
              h1, h2, h3 { line-height: 1.25; }
              pre, code { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
              pre { background: rgba(127,127,127,.12); padding: .75rem 1rem;
                    border-radius: 6px; overflow-x: auto; }
              code { background: rgba(127,127,127,.12); padding: .1em .35em;
                     border-radius: 4px; }
              pre code { background: transparent; padding: 0; }
              a { color: #0a66c2; text-decoration: none; border-bottom: 1px solid currentColor; }
              a:hover { filter: brightness(1.2); }
              blockquote { margin: 1rem 0; padding: .25rem 1rem;
                           border-left: 3px solid rgba(127,127,127,.4); color: inherit; }
              table { border-collapse: collapse; }
              th, td { padding: .35rem .6rem; border-bottom: 1px solid rgba(127,127,127,.3); }
              hr { border: 0; border-top: 1px solid rgba(127,127,127,.3); margin: 2rem 0; }
              .meta { color: rgba(127,127,127,.9); font-size: .9em; margin-bottom: 1.5rem; }
            </style>
            </head>
            <body>
            <div class="meta">\(escMeta)</div>
            \(body)
            </body>
            </html>
            """
    }
}
