import Foundation

public enum Sift {
    public static let version = "0.1.2"

    /// Conservative single-quote shell quoting. Pass-through for tokens
    /// that match `[A-Za-z0-9_./-]+`; otherwise wraps in single quotes
    /// and escapes embedded apostrophes the POSIX way.
    public static func shellQuote(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quick check used by `ensureInitialized()`.
    public static var isInitialized: Bool {
        FileManager.default.fileExists(atPath: Paths.initMarker.path)
    }

    public static func ensureInitialized() throws {
        if !isInitialized {
            throw SiftError(
                "sift isn't set up yet",
                suggestion: "run 'sift init' first"
            )
        }
    }

    public static func markInitialized() throws {
        try Paths.ensureSiftHome()
        FileManager.default.createFile(
            atPath: Paths.initMarker.path,
            contents: Data()
        )
    }

    /// Build an AlephClient. Prefers the `ALEPH_URL` / `ALEPH_API_KEY`
    /// environment variables — `sift auto` populates these for every
    /// subprocess so the agent doesn't need to touch the vault. Falls
    /// back to `<vault>/secrets.json` for direct human invocations,
    /// which requires the vault to be mounted.
    public static func makeAlephClient() throws -> AlephClient {
        let env = ProcessInfo.processInfo.environment
        var url = nonEmpty(env["ALEPH_URL"])
        var key = nonEmpty(env["ALEPH_API_KEY"])
        if url == nil || key == nil {
            let secrets = (try? SecretsStore.load()) ?? VaultSecrets()
            url = url ?? nonEmpty(secrets.alephURL)
            key = key ?? nonEmpty(secrets.alephAPIKey)
        }
        guard let url else {
            throw SiftError(
                "Aleph URL not set",
                suggestion: "run 'sift init' or 'sift vault set ALEPH_URL ...'"
            )
        }
        guard let key else {
            throw SiftError(
                "Aleph API key not set",
                suggestion: "run 'sift init' or 'sift vault set ALEPH_API_KEY ...'"
            )
        }
        return try AlephClient(baseURL: url, apiKey: key)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
