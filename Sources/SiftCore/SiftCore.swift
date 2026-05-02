import Foundation

public enum Sift {
    public static let version = "0.1.0"

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

    /// Build an AlephClient from Keychain creds. Throws with a nudge if
    /// either ALEPH_URL or ALEPH_API_KEY is missing.
    public static func makeAlephClient() throws -> AlephClient {
        guard let url = Keychain.get(Keychain.Key.alephURL) else {
            throw SiftError(
                "Aleph URL not set",
                suggestion: "run 'sift init' or 'sift vault set ALEPH_URL ...'"
            )
        }
        guard let key = Keychain.get(Keychain.Key.alephAPIKey) else {
            throw SiftError(
                "Aleph API key not set",
                suggestion: "run 'sift init' or 'sift vault set ALEPH_API_KEY ...'"
            )
        }
        return try AlephClient(baseURL: url, apiKey: key)
    }
}
