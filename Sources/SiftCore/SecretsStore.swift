import Foundation

/// Aleph + hosted-backend credentials persisted as JSON inside the
/// encrypted vault. The vault MUST be mounted before any of these calls
/// — there is no on-disk representation outside the sparseimage, and no
/// Keychain fallback. A locked vault means the secrets are unreadable.
public struct VaultSecrets: Codable, Sendable, Equatable {
    public var alephURL: String?
    public var alephAPIKey: String?
    public var hostedBaseURL: String?
    public var hostedAPIKey: String?
    public var hostedModelName: String?

    public init(
        alephURL: String? = nil,
        alephAPIKey: String? = nil,
        hostedBaseURL: String? = nil,
        hostedAPIKey: String? = nil,
        hostedModelName: String? = nil
    ) {
        self.alephURL = alephURL
        self.alephAPIKey = alephAPIKey
        self.hostedBaseURL = hostedBaseURL
        self.hostedAPIKey = hostedAPIKey
        self.hostedModelName = hostedModelName
    }
}

public enum SecretsStore {
    public static let filename = "secrets.json"

    public static func path(vaultMount: URL) -> URL {
        vaultMount.appending(path: filename)
    }

    /// Path inside the currently-mounted vault. Throws if no vault is
    /// mounted — callers that may run before unlock need to call
    /// `VaultService` first.
    public static func currentPath(vault: VaultService = VaultService()) throws -> URL {
        let mp = try vault.requireMounted()
        return path(vaultMount: mp)
    }

    /// Load from an explicit mount URL. Tests use this; production code
    /// goes through `load(vault:)` which derives the mount via
    /// `requireMounted()`.
    public static func load(mount: URL) throws -> VaultSecrets {
        let url = path(vaultMount: mount)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return VaultSecrets()
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return VaultSecrets() }
        return try JSONDecoder().decode(VaultSecrets.self, from: data)
    }

    /// Load secrets from the mounted vault. Missing file → empty struct
    /// (no creds yet). Throws on a vault that isn't mounted, or on a
    /// malformed JSON payload.
    public static func load(vault: VaultService = VaultService()) throws -> VaultSecrets {
        try load(mount: try vault.requireMounted())
    }

    /// Update at an explicit mount URL — atomic write, 0600. Used by
    /// tests; production code calls `update(vault:)`.
    public static func update(
        mount: URL,
        _ mutate: (inout VaultSecrets) throws -> Void
    ) throws {
        var current = try load(mount: mount)
        try mutate(&current)
        let url = path(vaultMount: mount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(current)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Read-modify-write inside the vault, atomic + 0600. Closure mutates
    /// the current secrets in place; an empty file is treated as an empty
    /// struct so first-time writes work.
    public static func update(
        vault: VaultService = VaultService(),
        _ mutate: (inout VaultSecrets) throws -> Void
    ) throws {
        try update(mount: try vault.requireMounted(), mutate)
    }
}
