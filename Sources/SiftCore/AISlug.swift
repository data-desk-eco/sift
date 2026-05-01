import Foundation

/// Ask the configured backend for a kebab-case slug for a session.
/// Falls back to a regex slug of the prompt if the LLM call fails.
public enum AISlug {
    public static func make(prompt: String, timeout: TimeInterval = 8) async -> String {
        if let aiSlug = await callBackend(prompt: prompt, timeout: timeout), !aiSlug.isEmpty {
            return aiSlug
        }
        return regexSlug(prompt)
    }

    static func regexSlug(_ prompt: String) -> String {
        let lowered = prompt.lowercased()
        var slug = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return String(slug.prefix(40))
    }

    static func sanitize(_ raw: String) -> String {
        var text = raw
        // strip <think>...</think> blocks
        if let re = try? NSRegularExpression(
            pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators
        ) {
            let range = NSRange(text.startIndex..., in: text)
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        let lines = text.split(whereSeparator: { $0.isNewline }).map { String($0) }
        guard let last = lines.map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return "" }
        let candidate = last
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
            .lowercased()
        var slug = ""
        for ch in candidate {
            if ch.isLetter || ch.isNumber || ch == "-" {
                slug.append(ch)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return String(slug.prefix(50))
    }

    private static func callBackend(
        prompt: String, timeout: TimeInterval
    ) async -> String? {
        guard let config = Backend.readConfig() else { return nil }

        let baseURL: String
        let apiKey: String
        switch config.kind {
        case .local:
            let port = config.port ?? Backend.defaultLocalPort
            baseURL = "http://127.0.0.1:\(port)/v1"
            apiKey = "sift-local"
        case .hosted:
            guard let url = config.baseURL else { return nil }
            baseURL = url
            apiKey = Keychain.get(Keychain.Key.hostedAPIKey) ?? ""
        }

        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/chat/completions") else { return nil }

        let body: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system",
                 "content": "You name research sessions with a short slug. "
                    + "Output only the slug — 2 to 5 lowercase words separated "
                    + "by hyphens, no punctuation, no quotes, no commentary, "
                    + "no preface. Focus on the subject of the investigation, "
                    + "not generic verbs."],
                ["role": "user", "content": "Investigation: \(prompt)"],
            ],
            "max_tokens": 32,
            "temperature": 0.2,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = (choices.first?["message"] as? [String: Any]),
                  let content = msg["content"] as? String
            else { return nil }
            let slug = sanitize(content)
            return slug.isEmpty ? nil : slug
        } catch {
            return nil
        }
    }
}
