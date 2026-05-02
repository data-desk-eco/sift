import Foundation

/// Ask the configured backend for a kebab-case slug for a session.
/// Falls back to a regex slug of the prompt if the LLM call fails.
public enum AISlug {
    /// `timeout` defaults to 8s. With `/no_think` and a warm idle local
    /// backend, slug generation finishes in well under a second; the
    /// short ceiling exists because the backend may be saturated by
    /// another active `sift auto` run (llama.cpp serializes requests),
    /// in which case we'd rather fall back to a regex slug than block
    /// the user.
    public static func make(prompt: String, timeout: TimeInterval = 8) async -> String {
        if let aiSlug = await callBackend(prompt: prompt, timeout: timeout), !aiSlug.isEmpty {
            return aiSlug
        }
        Log.say("slug", "LLM unavailable or slow — using regex slug")
        return regexSlug(prompt)
    }

    static func regexSlug(_ prompt: String) -> String {
        kebabify(prompt, allowHyphen: false, maxLength: 40)
    }

    static func sanitize(_ raw: String) -> String {
        // Strip any <think>…</think> reasoning blocks the model leaked
        // (Qwen3 normally honours `/no_think` but isn't 100% reliable).
        var text = raw
        if let re = try? NSRegularExpression(
            pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators
        ) {
            let range = NSRange(text.startIndex..., in: text)
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        // Take the last non-empty line — the slug instruction tells the
        // model "Output ONLY the slug on the final line."
        guard let last = text.split(whereSeparator: { $0.isNewline })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return "" }
        let stripped = last.trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
        return kebabify(stripped, allowHyphen: true, maxLength: 50)
    }

    /// Lowercase, alpha-numerics + (optionally) embedded hyphens; runs
    /// of other characters collapse to a single `-`. Truncated to
    /// `maxLength`, then leading/trailing hyphens stripped — order
    /// matters: a 40-char prefix that lands mid-word would otherwise
    /// leave a trailing `-`.
    static func kebabify(_ raw: String, allowHyphen: Bool, maxLength: Int) -> String {
        var slug = ""
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber || (allowHyphen && ch == "-") {
                slug.append(ch)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        slug = String(slug.prefix(maxLength))
        while slug.hasSuffix("-") { slug.removeLast() }
        while slug.hasPrefix("-") { slug.removeFirst() }
        return slug
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

        let systemPrompt = """
            You name OSINT investigation sessions with a concise, distinctive slug.

            Rules:
            - 2 to 5 lowercase words, separated by hyphens.
            - Identify the *subject* (person, company, vessel, place, document) — the proper noun, not the action.
            - Drop generic verbs like "investigate", "research", "look into", "find".
            - Drop filler like "the", "and", "of", articles, conjunctions.
            - No punctuation other than hyphens. No quotes, no commentary, no preface.
            - Output ONLY the slug on the final line.

            Examples:
            Investigation: who owns the cargo ship Stella M and what cargo did it carry between 2022 and 2024
            stella-m-ownership

            Investigation: look into the relationship between Wirecard and Jan Marsalek's network in Russia
            wirecard-marsalek-russia

            Investigation: any signs that Acme Corp is a shell for sanctioned Russian oligarchs
            acme-corp-shell-russia

            Investigation: trace ownership of the property at 12 Bishop's Avenue London
            bishops-avenue-property
            """
        // `/no_think` is a Qwen3 directive that suppresses the reasoning
        // loop for this request — turns a 30-60s call into a <1s one and
        // the slug task doesn't benefit from thinking anyway. Hosted
        // OpenAI-compatible models will simply ignore the token.
        let body: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "/no_think\nInvestigation: \(prompt)"],
            ],
            "max_tokens": 64,
            "temperature": 0.2,
            // Defensive: some chat templates honor this kwarg too.
            "chat_template_kwargs": ["enable_thinking": false],
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
