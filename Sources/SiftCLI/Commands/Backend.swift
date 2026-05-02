import ArgumentParser
import Foundation
import SiftCore

struct BackendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backend",
        abstract: "Show or switch the LLM backend.",
        subcommands: [BackendShow.self, BackendLocal.self, BackendHosted.self],
        defaultSubcommand: BackendShow.self
    )
}

struct BackendShow: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show the current backend config."
    )
    func execute() async throws {
        let config = try Backend.requireConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        print(String(data: data, encoding: .utf8) ?? "")
        // Note: hosted API key is not printed — it's in Keychain.
    }
}

struct BackendLocal: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "local",
        abstract: "Switch to local llama.cpp + Qwen3.6 35B."
    )
    func execute() async throws {
        try Backend.ensureLlamacpp()
        try Backend.downloadModel()
        try Backend.writeLocal()
        print("[backend]  switched to local")
    }
}

struct BackendHosted: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "hosted",
        abstract: "Switch to a hosted OpenAI-compatible endpoint."
    )
    func execute() async throws {
        let baseURL = promptUser("OpenAI-compatible base URL (e.g. https://api.openai.com/v1):")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            throw SiftError("base URL required")
        }
        let apiKey = promptUser("API key (leave blank for none):", secret: true)
        let modelName = promptUser("Model name (e.g. gpt-4o, llama-3.3-70b):")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw SiftError("model name required")
        }

        Log.say("backend", "checking endpoint...")
        try await checkEndpoint(baseURL: baseURL, apiKey: apiKey)
        try Backend.writeHosted(baseURL: baseURL, apiKey: apiKey, modelName: modelName)
        print("[backend]  switched to hosted")
    }

    private func checkEndpoint(baseURL: String, apiKey: String) async throws {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/models"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw SiftError(
                "base URL must use http or https",
                suggestion: "got: \(baseURL)"
            )
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw SiftError(
                    "endpoint returned HTTP \(http.statusCode)",
                    suggestion: "check the URL and key"
                )
            }
        } catch let error as SiftError {
            throw error
        } catch {
            throw SiftError(
                "couldn't reach \(trimmed)/models",
                suggestion: "check the URL and key"
            )
        }
    }
}
