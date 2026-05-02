import ArgumentParser
import Foundation
import SiftCore

struct VaultCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Vault management.",
        subcommands: [
            VaultInit.self, VaultUnlock.self, VaultLock.self, VaultStatus.self,
            VaultSet.self, VaultGet.self, VaultList.self, VaultEnv.self,
        ]
    )
}

struct VaultInit: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "init", abstract: "Create the encrypted sparseimage."
    )

    @Option(help: "sparseimage max size (e.g. 20g, 100g)")
    var size: String = VaultService.defaultSize

    func execute() async throws {
        let vault = VaultService()
        let passphrase = try promptNewVaultPassphrase()
        _ = try vault.initialize(passphrase: passphrase, size: size)
        print("✔ vault initialised")
        print("  sparseimage : \(vault.sparseimagePath.path)")
        print("  mounted at  : \(vault.defaultMountpoint.path)")
        print("")
        print("Save the passphrase in your password manager — sift never")
        print("stores it. Lose it and the vault is unrecoverable.")
        print("")
        print("Add your Aleph credentials next:")
        print("  sift vault set ALEPH_URL https://aleph.occrp.org")
        print("  sift vault set ALEPH_API_KEY <your-key>")
    }
}

struct VaultUnlock: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock", abstract: "Mount the vault (passphrase prompt)."
    )
    func execute() async throws {
        let mp = try requireVault()
        print(mp.path)
    }
}

struct VaultLock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock", abstract: "Unmount the vault."
    )
    func run() async throws {
        let locked = VaultService().lock()
        print(locked ? "locked." : "not mounted.")
    }
}

struct VaultStatus: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show whether the vault is mounted."
    )
    func execute() async throws {
        let v = VaultService()
        guard v.isCreated else {
            throw SiftError(
                "uninitialised",
                suggestion: "run 'sift vault init' to create \(v.sparseimagePath.path)"
            )
        }
        if let mp = v.findExistingMount() {
            print("mounted at \(mp.path)")
        } else {
            print("locked")
        }
    }
}

/// Sift's vault holds Aleph + hosted-backend creds in
/// `<mount>/secrets.json`. Two known keys map to the Aleph slot;
/// extending the surface to other keys means rejecting them here so a
/// typo doesn't silently land in the JSON file.
struct VaultSet: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Store a credential or config value."
    )
    @Argument var key: String
    @Argument var value: String

    func execute() async throws {
        _ = try requireVault()
        switch key {
        case "ALEPH_URL":
            try SecretsStore.update { $0.alephURL = value }
        case "ALEPH_API_KEY":
            try SecretsStore.update { $0.alephAPIKey = value }
        default:
            throw SiftError(
                "unknown key '\(key)'",
                suggestion: "known: ALEPH_URL, ALEPH_API_KEY"
            )
        }
        print("set \(key)")
    }
}

struct VaultGet: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Read a credential."
    )
    @Argument var key: String

    func execute() async throws {
        _ = try requireVault()
        let secrets = try SecretsStore.load()
        let value: String?
        switch key {
        case "ALEPH_URL":     value = secrets.alephURL
        case "ALEPH_API_KEY": value = secrets.alephAPIKey
        default:
            throw SiftError(
                "unknown key '\(key)'",
                suggestion: "known: ALEPH_URL, ALEPH_API_KEY"
            )
        }
        guard let v = value, !v.isEmpty else {
            throw SiftError("no value stored for '\(key)'")
        }
        print(v)
    }
}

struct VaultList: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List stored credential keys (values not shown)."
    )
    func execute() async throws {
        _ = try requireVault()
        let secrets = try SecretsStore.load()
        var keys: [String] = []
        if let v = secrets.alephURL,    !v.isEmpty { keys.append("ALEPH_URL") }
        if let v = secrets.alephAPIKey, !v.isEmpty { keys.append("ALEPH_API_KEY") }
        print(keys.isEmpty ? "(empty)" : keys.joined(separator: "\n"))
    }
}

struct VaultEnv: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Print export statements for vault env (eval-friendly)."
    )
    func execute() async throws {
        let mp = try requireVault()
        let secrets = (try? SecretsStore.load()) ?? VaultSecrets()
        var env: [(String, String)] = [
            ("VAULT_MOUNT", mp.path),
            ("ALEPH_SESSION_DIR", mp.appending(path: "research").path),
        ]
        if let url = secrets.alephURL, !url.isEmpty {
            env.append(("ALEPH_URL", url))
        }
        if let key = secrets.alephAPIKey, !key.isEmpty {
            env.append(("ALEPH_API_KEY", key))
        }
        for (k, v) in env {
            print("export \(k)=\(Sift.shellQuote(v))")
        }
    }
}
