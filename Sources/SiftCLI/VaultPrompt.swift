import Darwin
import Foundation
import SiftCore

/// Vault unlock helper used by every command that needs the
/// sparseimage mounted. Lifecycle:
///
///   1. If a mountpoint already exists, return it (no prompt).
///   2. Otherwise, read `SIFT_VAULT_PASSPHRASE` from the environment
///      if it's set (CI / Shortcuts escape hatch — opt-in only because
///      env vars leak into subprocesses and `ps` listings).
///   3. Otherwise, `getpass()` interactively. Without a TTY this fails
///      cleanly with a SiftError pointing the user at `sift vault unlock`.
///
/// Returns the mountpoint. The passphrase is dropped on return — the
/// caller never sees it.
@discardableResult
func requireVault(reason: String = "Unlock the sift vault") throws -> URL {
    let vault = VaultService()
    if let mp = vault.findExistingMount() { return mp }
    guard vault.isCreated else {
        throw SiftError(
            "vault not initialised",
            suggestion: "run 'sift init' first"
        )
    }
    let passphrase = try readVaultPassphrase(reason: reason)
    return try vault.unlock(passphrase: passphrase, reason: reason)
}

/// Same as `requireVault()` but for `sift init`'s create flow — prompts
/// twice with confirmation. Errors fast on mismatched or empty input
/// rather than creating a vault the user can't open.
func promptNewVaultPassphrase() throws -> String {
    if let env = ProcessInfo.processInfo.environment["SIFT_VAULT_PASSPHRASE"],
       !env.isEmpty {
        return env
    }
    guard isatty(fileno(stdin)) != 0 else {
        throw SiftError(
            "no TTY available for passphrase prompt",
            suggestion: "set SIFT_VAULT_PASSPHRASE in the environment, or run 'sift init' from a terminal"
        )
    }
    FileHandle.standardError.write(Data("""

        Choose a passphrase for the encrypted vault. sift will NOT store it
        — it lives only in your head (or your password manager). Lose it
        and the vault is unrecoverable.


        """.utf8))
    let first = readSecret("Passphrase:")
    guard !first.isEmpty else {
        throw SiftError("passphrase must not be empty")
    }
    let second = readSecret("Confirm:")
    guard first == second else {
        throw SiftError("passphrases didn't match — try again")
    }
    return first
}

private func readVaultPassphrase(reason: String) throws -> String {
    if let env = ProcessInfo.processInfo.environment["SIFT_VAULT_PASSPHRASE"],
       !env.isEmpty {
        return env
    }
    guard isatty(fileno(stdin)) != 0 else {
        throw SiftError(
            "vault is locked and no TTY available for passphrase prompt",
            suggestion: "run 'sift vault unlock' from a terminal first, or set SIFT_VAULT_PASSPHRASE in the environment"
        )
    }
    FileHandle.standardError.write(Data("\(reason).\n".utf8))
    let pp = readSecret("Vault passphrase:")
    guard !pp.isEmpty else {
        throw SiftError("passphrase must not be empty")
    }
    return pp
}

private func readSecret(_ prompt: String) -> String {
    FileHandle.standardError.write(Data("\(prompt) ".utf8))
    if let raw = String(validatingCString: getpass("")) { return raw }
    return ""
}
