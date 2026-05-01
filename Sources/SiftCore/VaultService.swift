import CommonCrypto
import Foundation

/// Encrypted vault backed by an APFS sparseimage on macOS, gated by Touch ID.
///
/// One vault per `siftHome` (default `~/.sift`). The passphrase lives in the
/// login keychain — there's no on-disk passphrase file, so a stolen home
/// directory yields nothing.
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

    public struct InitResult: Sendable {
        public let mountpoint: URL
        public let passphrase: String
    }

    /// Create the sparseimage and mount it. Stores the passphrase in
    /// Keychain. Throws if a vault already exists.
    public func initialize(size: String = defaultSize) throws -> InitResult {
        if isCreated {
            throw SiftError(
                "vault already exists at \(sparseimagePath.path)",
                suggestion: "use 'sift vault unlock' to mount"
            )
        }
        try Paths.ensure(projectDir)

        let passphrase = Self.randomPassphrase()
        let stem = sparseimagePath.deletingPathExtension().path

        try Subprocess.check(
            ["/usr/bin/hdiutil", "create",
             "-size", size, "-encryption", "AES-256",
             "-type", "SPARSE", "-fs", "APFS",
             "-volname", volumeName,
             "-stdinpass", stem],
            input: passphrase
        )
        Keychain.set(Keychain.Key.vaultPassphrase, passphrase)

        try Subprocess.check(
            ["/usr/bin/hdiutil", "attach", "-stdinpass",
             "-mountpoint", defaultMountpoint.path, sparseimagePath.path],
            input: passphrase
        )
        try Paths.ensure(defaultMountpoint.appending(path: "research"))
        return InitResult(mountpoint: defaultMountpoint, passphrase: passphrase)
    }

    /// Mount the vault if not already mounted. Touch-ID gated.
    @discardableResult
    public func unlock(reason: String = "Unlock the sift vault") throws -> URL {
        if let existing = findExistingMount() { return existing }
        guard isCreated else {
            throw SiftError(
                "vault not initialised",
                suggestion: "run 'sift vault init' first"
            )
        }
        guard TouchID.confirm(reason: reason) else {
            throw SiftError("Touch ID cancelled or failed")
        }
        guard let passphrase = Keychain.get(Keychain.Key.vaultPassphrase) else {
            throw SiftError(
                "vault passphrase missing from Keychain",
                suggestion: "destroy and recreate: 'rm \(sparseimagePath.path) && sift vault init'"
            )
        }
        try Subprocess.check(
            ["/usr/bin/hdiutil", "attach", "-stdinpass",
             "-mountpoint", defaultMountpoint.path, sparseimagePath.path],
            input: passphrase
        )
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

    static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
