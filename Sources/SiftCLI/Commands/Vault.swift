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
        _ = try vault.initialize(size: size)
        print("✔ vault initialised")
        print("  sparseimage : \(vault.sparseimagePath.path)")
        print("  mounted at  : \(vault.defaultMountpoint.path)")
        print("")
        print("The passphrase is stored in your macOS login keychain")
        print("(service \"\(Keychain.service)\", account \"\(Keychain.Key.vaultPassphrase)\")")
        print("with a Touch-ID / login-password ACL. It is device-only —")
        print("it does NOT sync to iCloud — so if you ever lose this Mac")
        print("the sparseimage above can't be decrypted.")
        print("")
        print("To back it up: open Keychain Access.app, search for")
        print("\"\(Keychain.service)\", and copy the password into")
        print("your password manager. (Touch ID will gate the reveal.)")
        print("")
        print("Add your Aleph credentials next:")
        print("  sift vault set ALEPH_URL https://aleph.occrp.org")
        print("  sift vault set ALEPH_API_KEY <your-key>")
    }
}

struct VaultUnlock: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock", abstract: "Mount the vault (Touch ID gated)."
    )
    func execute() async throws {
        let mp = try VaultService().unlock()
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

/// Sift's vault holds non-secret config (Aleph URL, optional alt
/// servers) on the encrypted volume; actual secrets (API keys,
/// passphrase) live in Keychain. Two known keys map to Keychain
/// entries; everything else lands in `<mount>/config.json` for the
/// research session to read.
struct VaultSet: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Store a credential or config value."
    )
    @Argument var key: String
    @Argument var value: String

    func execute() async throws {
        switch key {
        case "ALEPH_URL":
            Keychain.set(Keychain.Key.alephURL, value)
        case "ALEPH_API_KEY":
            Keychain.set(Keychain.Key.alephAPIKey, value)
        default:
            _ = try VaultService().requireMounted()
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
        let value: String?
        switch key {
        case "ALEPH_URL":     value = Keychain.get(Keychain.Key.alephURL)
        case "ALEPH_API_KEY": value = Keychain.get(Keychain.Key.alephAPIKey)
        default:
            throw SiftError(
                "unknown key '\(key)'",
                suggestion: "known: ALEPH_URL, ALEPH_API_KEY"
            )
        }
        guard let v = value else {
            throw SiftError("no value stored for '\(key)'")
        }
        print(v)
    }
}

struct VaultList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List stored credential keys (values not shown)."
    )
    func run() async throws {
        let stored = Keychain.keys()
            .filter { $0.hasPrefix("aleph.") || $0 == Keychain.Key.vaultPassphrase }
        let display = stored.compactMap { key -> String? in
            switch key {
            case Keychain.Key.alephURL: return "ALEPH_URL"
            case Keychain.Key.alephAPIKey: return "ALEPH_API_KEY"
            case Keychain.Key.vaultPassphrase: return nil
            default: return key
            }
        }
        print(display.isEmpty ? "(empty)" : display.joined(separator: "\n"))
    }
}

struct VaultEnv: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Print export statements for vault env (eval-friendly)."
    )
    func execute() async throws {
        let mp = try VaultService().requireMounted()
        var env: [(String, String)] = [
            ("VAULT_MOUNT", mp.path),
            ("ALEPH_SESSION_DIR", mp.appending(path: "research").path),
        ]
        if let url = Keychain.get(Keychain.Key.alephURL) {
            env.append(("ALEPH_URL", url))
        }
        if let key = Keychain.get(Keychain.Key.alephAPIKey) {
            env.append(("ALEPH_API_KEY", key))
        }
        for (k, v) in env {
            print("export \(k)=\(Sift.shellQuote(v))")
        }
    }
}
