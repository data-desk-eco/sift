import Foundation

/// LLM backend manager: on-disk config, pi provider config, local
/// llama.cpp daemon lifecycle. The hosted path is config-only.
public enum Backend {

    public static let defaultLocalPort = 1234
    public static let defaultModelRepo = "unsloth/Qwen3.6-35B-A3B-GGUF"
    public static let defaultModelFile = "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf"
    public static let defaultModelName = "qwen3.6-35b-a3b"
    public static let defaultModelDisplay = "Qwen3.6 35B A3B (local)"
    public static let localContextWindow = 262_144

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
            let port = config.port ?? defaultLocalPort
            baseURL = "http://127.0.0.1:\(port)/v1"
            apiKey = "sift-local"
            display = defaultModelDisplay
        case .hosted:
            guard let url = config.baseURL else {
                throw SiftError("hosted backend missing base URL")
            }
            baseURL = url
            apiKey = Keychain.get(Keychain.Key.hostedAPIKey) ?? ""
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

    // MARK: - Local llama-server lifecycle

    public static func healthCheck(port: Int, timeout: TimeInterval = 1) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                ok = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        if !ok { task.cancel() }
        return ok
    }

    /// Spawn `llama-server` detached, write pidfile, poll until ready.
    public static func startLocal() throws {
        let config = try requireConfig()
        guard config.kind == .local else { return }
        let port = config.port ?? defaultLocalPort
        if healthCheck(port: port) {
            FileHandle.standardError.write(Data("[server]   already up on :\(port)\n".utf8))
            return
        }
        let modelPath = Paths.modelsDir.appending(path: config.modelFile ?? defaultModelFile)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw SiftError(
                "model not found at \(modelPath.path)",
                suggestion: "run 'sift init' to download it"
            )
        }
        let logPath = Paths.siftHome.appending(path: "llama-server.log")
        let pidPath = Paths.siftHome.appending(path: "llama-server.pid")
        FileHandle.standardError.write(Data("[server]   starting llama-server on :\(port)\n".utf8))

        if !FileManager.default.fileExists(atPath: logPath.path) {
            FileManager.default.createFile(atPath: logPath.path, contents: nil)
        }
        guard let logHandle = try? FileHandle(forWritingTo: logPath) else {
            throw SiftError("can't write to \(logPath.path)")
        }
        try logHandle.seekToEnd()

        let proc = Process()
        proc.executableURL = URL(filePath: try resolveExecutable("llama-server"))
        proc.arguments = [
            "--model", modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--jinja",
            "--no-webui",
            "--ctx-size", String(localContextWindow),
            "--reasoning-budget", "16384",
            "--alias", config.modelName,
        ]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        // Detach the new process from our session so it survives our exit.
        // This is the analogue of Python's start_new_session=True.
        try proc.run()
        try? Data(String(proc.processIdentifier).utf8).write(to: pidPath)

        for _ in 0..<120 {
            Thread.sleep(forTimeInterval: 1.0)
            if healthCheck(port: port) {
                FileHandle.standardError.write(Data("[server]   ready\n".utf8))
                return
            }
        }
        throw SiftError(
            "llama-server didn't become ready in 120s",
            suggestion: "check \(logPath.path)"
        )
    }

    /// Start whichever backend is configured. Hosted is config-only.
    public static func start() throws {
        let config = try requireConfig()
        switch config.kind {
        case .local:  try startLocal()
        case .hosted: return
        }
    }

    // MARK: - Setup helpers

    public static func ensureLlamacpp() throws {
        if Subprocess.which("llama-server") != nil { return }
        guard Subprocess.which("brew") != nil else {
            throw SiftError(
                "llama-server not installed and Homebrew not found",
                suggestion: "install Homebrew or install llama.cpp manually"
            )
        }
        FileHandle.standardError.write(Data("[init]     installing llama.cpp via Homebrew\n".utf8))
        try Subprocess.check(["/usr/bin/env", "brew", "install", "llama.cpp"])
    }

    /// Download the recommended GGUF model into `~/.sift/models/`.
    /// Resolves the HF redirect first so curl's progress bar tracks the
    /// actual download, not the redirect document.
    public static func downloadModel() throws {
        try Paths.ensure(Paths.modelsDir)
        let modelPath = Paths.modelsDir.appending(path: defaultModelFile)
        if FileManager.default.fileExists(atPath: modelPath.path) {
            FileHandle.standardError.write(Data("[init]     model already downloaded\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("[init]     downloading model (~12 GB)\n".utf8))

        let resolveURL = "https://huggingface.co/\(defaultModelRepo)/resolve/main/\(defaultModelFile)"
        let resolved = try resolveRedirect(resolveURL)
        let partial = modelPath.appendingPathExtension("partial")
        try Subprocess.check([
            "/usr/bin/env", "curl", "--fail", "--progress-bar",
            "--retry", "5", "--retry-all-errors",
            "-o", partial.path, resolved,
        ])
        try FileManager.default.moveItem(at: partial, to: modelPath)
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
        Keychain.set(Keychain.Key.hostedAPIKey, apiKey)
    }

    // MARK: - Internal

    private static func writePrettyJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    private static func resolveExecutable(_ name: String) throws -> String {
        guard let path = Subprocess.which(name) else {
            throw SiftError(
                "missing dependency: \(name)",
                suggestion: "install: brew install llama.cpp"
            )
        }
        return path
    }

    /// Follow HEAD redirects manually so curl downloads the resolved URL
    /// (HF gives a CDN-signed URL via 302).
    private static func resolveRedirect(_ url: String) throws -> String {
        var current = url
        for _ in 0..<5 {
            guard let u = URL(string: current) else { break }
            var request = URLRequest(url: u)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 30
            let sem = DispatchSemaphore(value: 0)
            var resolved: String?
            var statusCode: Int = 0
            let session = URLSession(configuration: .ephemeral, delegate: NoFollowRedirect(), delegateQueue: nil)
            let task = session.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse {
                    statusCode = http.statusCode
                    if (300..<400).contains(http.statusCode),
                       let loc = http.value(forHTTPHeaderField: "Location") {
                        resolved = loc
                    }
                }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 30)
            if let next = resolved {
                current = next.hasPrefix("http") ? next : URL(string: next, relativeTo: u)?.absoluteString ?? next
            } else if (200..<300).contains(statusCode) {
                return current
            } else {
                break
            }
        }
        return current
    }

    private final class NoFollowRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
