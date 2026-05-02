import Foundation
import Testing
@testable import SiftCore

@Suite struct SecretsStoreTests {

    private func tmpMount() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadOnEmptyMountReturnsBlankStruct() throws {
        let mount = try tmpMount()
        defer { try? FileManager.default.removeItem(at: mount) }

        let secrets = try SecretsStore.load(mount: mount)
        #expect(secrets.alephURL == nil)
        #expect(secrets.alephAPIKey == nil)
    }

    @Test func roundTripPreservesAllFields() throws {
        let mount = try tmpMount()
        defer { try? FileManager.default.removeItem(at: mount) }

        try SecretsStore.update(mount: mount) { s in
            s.alephURL = "https://aleph.example.org"
            s.alephAPIKey = "k1"
            s.hostedBaseURL = "https://api.example.com/v1"
            s.hostedAPIKey = "k2"
            s.hostedModelName = "gpt-4o"
        }
        let loaded = try SecretsStore.load(mount: mount)
        #expect(loaded.alephURL == "https://aleph.example.org")
        #expect(loaded.alephAPIKey == "k1")
        #expect(loaded.hostedBaseURL == "https://api.example.com/v1")
        #expect(loaded.hostedAPIKey == "k2")
        #expect(loaded.hostedModelName == "gpt-4o")
    }

    @Test func partialUpdateLeavesOtherFieldsIntact() throws {
        let mount = try tmpMount()
        defer { try? FileManager.default.removeItem(at: mount) }

        try SecretsStore.update(mount: mount) { s in
            s.alephURL = "u"
            s.alephAPIKey = "k"
        }
        try SecretsStore.update(mount: mount) { s in
            s.hostedAPIKey = "h"
        }
        let loaded = try SecretsStore.load(mount: mount)
        #expect(loaded.alephURL == "u")
        #expect(loaded.alephAPIKey == "k")
        #expect(loaded.hostedAPIKey == "h")
    }

    @Test func writesFileAtSecretsJSON() throws {
        let mount = try tmpMount()
        defer { try? FileManager.default.removeItem(at: mount) }

        try SecretsStore.update(mount: mount) { $0.alephURL = "u" }
        let file = mount.appending(path: "secrets.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func loadThrowsWhenVaultNotMounted() throws {
        // VaultService against a project dir that has no sparseimage —
        // `requireMounted` raises before we touch any secrets file.
        let projectDir = FileManager.default.temporaryDirectory
            .appending(path: "sift-secrets-novault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let vault = VaultService(projectDir: projectDir)
        #expect(throws: SiftError.self) {
            _ = try SecretsStore.load(vault: vault)
        }
    }
}
