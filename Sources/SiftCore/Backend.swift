import Foundation

/// LLM backend configuration: the on-disk `backend.json` schema and
/// the pi-config templating that points pi at the configured endpoint.
/// Process lifecycle for the local llama-server lives in `LlamaServer`.
public enum Backend {

    public static let defaultLocalPort = 1234
    public static let defaultProxyPort = ForgeProxy.defaultProxyPort
    public static let defaultModelFile = "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf"
    public static let defaultModelName = "qwen3.6-35b-a3b"
    public static let defaultModelDisplay = "Qwen3.6 35B A3B (local)"
    public static let localContextWindow = 131_072

    // MARK: - Config

    public enum Kind: String, Codable, Sendable {
        case local
        case hosted
    }

    public struct Config: Codable, Sendable {
        public var kind: Kind
        public var port: Int?
        public var modelName: String
        public var modelFile: String?
        public var baseURL: String?

        public static func makeLocal(
            modelFile: String = Backend.defaultModelFile,
            modelName: String = Backend.defaultModelName,
            port: Int = Backend.defaultLocalPort
        ) -> Config {
            Config(kind: .local, port: port, modelName: modelName,
                   modelFile: modelFile, baseURL: nil)
        }

        public static func makeHosted(baseURL: String, modelName: String) -> Config {
            Config(kind: .hosted, port: nil, modelName: modelName,
                   modelFile: nil, baseURL: baseURL)
        }
    }

    public static var configPath: URL {
        Paths.siftHome.appending(path: "backend.json")
    }

    public static func readConfig() -> Config? {
        guard let data = try? Data(contentsOf: configPath) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    public static func writeConfig(_ config: Config) throws {
        try Paths.ensureSiftHome()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configPath)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configPath.path
        )
    }

    public static func requireConfig() throws -> Config {
        guard let c = readConfig() else {
            throw SiftError(
                "no backend configured",
                suggestion: "run 'sift init' or 'sift backend local|hosted'"
            )
        }
        return c
    }

    public static func writeLocal(
        modelFile: String = defaultModelFile,
        modelName: String = defaultModelName,
        port: Int = defaultLocalPort
    ) throws {
        try writeConfig(.makeLocal(modelFile: modelFile, modelName: modelName, port: port))
    }

    public static func writeHosted(
        baseURL: String, apiKey: String, modelName: String
    ) throws {
        try writeConfig(.makeHosted(baseURL: baseURL, modelName: modelName))
        try SecretsStore.update { secrets in
            secrets.hostedBaseURL = baseURL
            secrets.hostedAPIKey = apiKey
            secrets.hostedModelName = modelName
        }
    }

    // MARK: - pi config

    /// Write `pi/models.json` and `pi/settings.json` so pi talks to the
    /// configured backend. Called every `sift auto` so the local port
    /// stays in sync.
    public static func configurePi() throws {
        let config = try requireConfig()
        let baseURL: String
        let apiKey: String
        let display: String
        switch config.kind {
        case .local:
            // Point pi at the forge proxy, not llama-server directly.
            // PiRunner.prepare() brings both processes up before this
            // runs, so the proxy is always reachable on `defaultProxyPort`.
            baseURL = "http://127.0.0.1:\(defaultProxyPort)/v1"
            apiKey = "sift-local"
            display = defaultModelDisplay
        case .hosted:
            guard let url = config.baseURL else {
                throw SiftError("hosted backend missing base URL")
            }
            baseURL = url
            apiKey = (try? SecretsStore.load().hostedAPIKey) ?? ""
            display = config.modelName
        }
        try Paths.ensure(Paths.piConfigDir)

        var modelEntry: [String: Any] = ["id": config.modelName, "name": display]
        if config.kind == .local {
            modelEntry["contextWindow"] = localContextWindow
        }
        let models: [String: Any] = [
            "providers": [
                "sift": [
                    "baseUrl": baseURL,
                    "api": "openai-completions",
                    "apiKey": apiKey,
                    "compat": [
                        "supportsDeveloperRole": false,
                        "supportsReasoningEffort": false,
                    ],
                    "models": [modelEntry],
                ],
            ],
        ]
        let settings: [String: Any] = [
            "defaultProvider": "sift",
            "defaultModel": config.modelName,
        ]

        try writePrettyJSON(models, to: Paths.piConfigDir.appending(path: "models.json"))
        try writePrettyJSON(settings, to: Paths.piConfigDir.appending(path: "settings.json"))
    }

    // MARK: - Internal

    private static func writePrettyJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }
}
