import Foundation

/// Filter pi's `--mode json` stream into terse `[scope] message` log
/// lines so detached runs aren't silent. With debug=true, every event
/// passes through unmodified (one JSON object per line).
public struct EventStream {
    public struct Line: Sendable {
        /// `[session]`, `[tool]`, `[done]`, …. Empty for blank spacer lines.
        public let scope: String
        /// Right-hand text after the padded `[scope]` tag.
        public let message: String
        /// Pre-rendered "[scope]   message" line, ready to write to a log.
        public let formatted: String
        /// True when this line is the agent's final assistant text.
        public let isFinalText: Bool

        public init(scope: String, message: String, formatted: String, isFinalText: Bool = false) {
            self.scope = scope
            self.message = message
            self.formatted = formatted
            self.isFinalText = isFinalText
        }
    }

    private var finalTextParts: [String] = []
    public var debug: Bool

    public init(debug: Bool = false) { self.debug = debug }

    /// Process one line from pi's stdout. Returns zero or more rendered
    /// lines to emit. State (e.g. accumulated final assistant text) is
    /// preserved across calls.
    public mutating func ingest(_ raw: String) -> [Line] {
        let trimmed = raw.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty { return [] }

        if debug {
            return [Line(scope: "raw", message: trimmed, formatted: trimmed)]
        }

        guard let data = trimmed.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [Line(scope: "raw", message: trimmed, formatted: log("raw", trimmed))]
        }

        let type = (event["type"] as? String) ?? ""
        switch type {
        case "session":
            let id = String((event["id"] as? String ?? "").prefix(8))
            return [Line(scope: "session", message: id, formatted: log("session", id))]

        case "agent_start":
            return [Line(scope: "agent", message: "start", formatted: log("agent", "start"))]

        case "tool_execution_start":
            let name = (event["toolName"] as? String) ?? "?"
            let preview = argsPreview(event["args"])
            let msg = "\(name): \(preview)"
            return [Line(scope: "tool", message: msg, formatted: log("tool", msg))]

        case "tool_execution_end":
            if (event["isError"] as? Bool) == true {
                let name = (event["toolName"] as? String) ?? "?"
                let result = short(string(event["result"]), to: 160)
                let msg = "\(name): \(result)"
                return [Line(scope: "tool!", message: msg, formatted: log("tool!", msg))]
            }
            return []

        case "message_end":
            if let message = event["message"] as? [String: Any],
               (message["role"] as? String) == "assistant",
               let content = message["content"] as? [[String: Any]] {
                finalTextParts = content
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
            }
            return []

        case "compaction_start":
            return [Line(scope: "compact", message: "start", formatted: log("compact", "start"))]

        case "compaction_end":
            return [Line(scope: "compact", message: "end", formatted: log("compact", "end"))]

        case "error":
            let raw = string(event["message"]).isEmpty
                ? string(event)
                : string(event["message"])
            let msg = short(raw, to: 200)
            return [Line(scope: "error", message: msg, formatted: log("error", msg))]

        case "agent_end":
            var lines: [Line] = []
            let text = finalTextParts
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(Line(scope: "", message: "", formatted: ""))
                lines.append(Line(scope: "final", message: text, formatted: text, isFinalText: true))
            }
            lines.append(Line(scope: "done", message: "", formatted: log("done", "")))
            return lines

        default:
            return []
        }
    }

    public var finalText: String {
        finalTextParts
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - helpers

    private func log(_ scope: String, _ msg: String) -> String {
        let tag = "[\(scope)]"
        let padded = tag.count >= 9 ? tag : tag + String(repeating: " ", count: 9 - tag.count)
        if msg.isEmpty {
            // Trim trailing whitespace.
            return padded.trimmingCharacters(in: .whitespaces)
        }
        return padded + " " + msg
    }

    private func short(_ value: String, to limit: Int = 100) -> String {
        let collapsed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "\u{2026}"
    }

    private func string(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case nil, is NSNull: return ""
        case let v?: return "\(v)"
        }
    }

    private func argsPreview(_ args: Any?) -> String {
        if let dict = args as? [String: Any] {
            for k in ["command", "cmd", "path", "file_path", "file", "query", "url", "pattern"] {
                if let v = dict[k], !string(v).isEmpty {
                    return short(string(v))
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                return short(s)
            }
            return ""
        }
        return short(string(args))
    }
}
