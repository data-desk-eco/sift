import CommonCrypto
import Foundation

/// Encrypted vault backed by an APFS sparseimage on macOS.
///
/// One vault per `siftHome` (default `~/.sift`). The user picks the
/// passphrase at `sift init` time and is responsible for storing it (a
/// password manager is fine). sift never persists it: every CLI
/// invocation that needs to mount the vault prompts for it, then drops
/// it on exit. After a successful unlock, subsequent invocations reuse
/// the existing mountpoint and don't prompt again until the user runs
/// `sift vault lock` or reboots.
public final class VaultService: @unchecked Sendable {
    public static let defaultSize = "20g"
    public static let filename = ".vault.sparseimage"

    private let projectDir: URL

    public init(projectDir: URL = Paths.siftHome) {
        self.projectDir = projectDir
    }

    public var sparseimagePath: URL { projectDir.appending(path: Self.filename) }

    public var projectHash: String {
        let data = projectDir.path.data(using: .utf8) ?? Data()
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &hash) }
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public var volumeName: String { "sift-vault-\(projectHash)" }
    public var defaultMountpoint: URL { URL(filePath: "/Volumes/\(volumeName)") }
    public var isCreated: Bool { FileManager.default.fileExists(atPath: sparseimagePath.path) }

    // MARK: - Lifecycle

    /// Create the sparseimage with `passphrase` and mount it. Returns the
    /// mountpoint. Throws if a vault already exists. The caller is
    /// responsible for prompting the user for `passphrase` (twice, with
    /// confirmation) — `sift init` does this.
    @discardableResult
    public func initialize(passphrase: String, size: String = defaultSize) throws -> URL {
        if isCreated {
            throw SiftError(
                "vault already exists at \(sparseimagePath.path)",
                suggestion: "delete it (`rm \(sparseimagePath.path)`) and re-run 'sift init' if you've forgotten the passphrase — there is NO recovery"
            )
        }
        guard !passphrase.isEmpty else {
            throw SiftError("vault passphrase must not be empty")
        }
        try Paths.ensure(projectDir)

        let stem = sparseimagePath.deletingPathExtension().path

        try Subprocess.check(
            ["/usr/bin/hdiutil", "create",
             "-size", size, "-encryption", "AES-256",
             "-type", "SPARSE", "-fs", "APFS",
             "-volname", volumeName,
             "-stdinpass", stem],
            input: passphrase
        )

        try Subprocess.check(
            ["/usr/bin/hdiutil", "attach", "-stdinpass",
             "-mountpoint", defaultMountpoint.path, sparseimagePath.path],
            input: passphrase
        )
        try Paths.ensure(defaultMountpoint.appending(path: "research"))
        return defaultMountpoint
    }

    /// Mount the vault if not already mounted. The caller supplies the
    /// `passphrase` — typically by prompting the user via `getpass`.
    /// `reason` is unused (kept for call-site readability).
    @discardableResult
    public func unlock(passphrase: String, reason: String = "Unlock the sift vault") throws -> URL {
        if let existing = findExistingMount() { return existing }
        guard isCreated else {
            throw SiftError(
                "vault not initialised",
                suggestion: "run 'sift init' first"
            )
        }
        guard !passphrase.isEmpty else {
            throw SiftError("vault passphrase must not be empty")
        }
        do {
            try Subprocess.check(
                ["/usr/bin/hdiutil", "attach", "-stdinpass",
                 "-mountpoint", defaultMountpoint.path, sparseimagePath.path],
                input: passphrase
            )
        } catch {
            // Two CLIs racing to unlock can both call hdiutil attach;
            // the second errors with "resource busy". If a mountpoint
            // appeared in the meantime, that's a win — return it.
            if let existing = findExistingMount() { return existing }
            throw error
        }
        return defaultMountpoint
    }

    @discardableResult
    public func lock() -> Bool {
        guard let mp = findExistingMount() else { return false }
        return (try? Subprocess.check(["/usr/bin/hdiutil", "detach", mp.path])) != nil
    }

    public func findExistingMount() -> URL? {
        guard isCreated else { return nil }
        let target = (sparseimagePath.path as NSString).resolvingSymlinksInPath

        guard let res = try? Subprocess.run(["/usr/bin/hdiutil", "info", "-plist"]),
              res.code == 0,
              let data = res.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return nil }

        for image in images {
            guard let path = image["image-path"] as? String,
                  (path as NSString).resolvingSymlinksInPath == target
            else { continue }
            for entity in (image["system-entities"] as? [[String: Any]]) ?? [] {
                if let mp = entity["mount-point"] as? String {
                    return URL(filePath: mp)
                }
            }
        }
        return nil
    }

    /// Convenience: vault must be mounted, returns the mountpoint or throws.
    public func requireMounted() throws -> URL {
        guard let mp = findExistingMount() else {
            throw SiftError("vault is not mounted", suggestion: "run 'sift vault unlock'")
        }
        return mp
    }

    /// Per-session research dir under the vault.
    public func researchDir() throws -> URL {
        let mp = try requireMounted()
        let dir = mp.appending(path: "research")
        try Paths.ensure(dir)
        return dir
    }
}
