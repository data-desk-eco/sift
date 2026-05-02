import ArgumentParser
import Foundation
import SiftCore

struct InitCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "One-time setup: vault, Aleph credentials, LLM backend, project."
    )

    func execute() async throws {
        // pi is installed by the sift installer into Application
        // Support, so the only failure here is "the user ran the CLI
        // without running the installer".
        if Paths.findExecutable("pi") == nil {
            throw SiftError(
                "the pi agent harness isn't installed",
                suggestion: "re-run the sift installer, or `make install-pi` from a source checkout"
            )
        }
        try Paths.ensureSiftHome()

        let vault = VaultService()
        let firstRun = !vault.isCreated
        if firstRun {
            Log.say("init", "creating encrypted vault at \(vault.sparseimagePath.path)")
            _ = try vault.initialize()
            Log.say("init", "passphrase stored in Keychain (\(Keychain.service)) — back it up via Keychain Access.app if you want a recovery copy off this Mac")
        } else {
            Log.say("init", "vault already exists")
            _ = try vault.unlock()
        }

        Log.say("init", "configuring Aleph credentials")
        let url = promptUser("Aleph URL [https://aleph.occrp.org]:")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let alephURL = url.isEmpty ? "https://aleph.occrp.org" : url
        let alephKey = promptUser("Aleph API key:", secret: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alephKey.isEmpty else {
            throw SiftError("Aleph API key required")
        }
        Keychain.set(Keychain.Key.alephURL, alephURL)
        Keychain.set(Keychain.Key.alephAPIKey, alephKey)

        if Backend.readConfig() != nil {
            Log.say("init", "backend already configured (use 'sift backend' to change)")
        } else {
            try await chooseBackendInteractive()
        }

        if !FileManager.default.fileExists(atPath: Paths.projectFile.path) {
            let desc = promptUser("\nBriefly describe the project (data source and subject):")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                try (desc + "\n").write(to: Paths.projectFile, atomically: true, encoding: .utf8)
            } else {
                Log.say("init", "skipped — set later with 'sift project set'")
            }
        } else {
            Log.say("init", "project context already set")
        }

        try Sift.markInitialized()
        print("[init]     done — try: sift auto \"investigate <subject>\"")
    }

    private func chooseBackendInteractive() async throws {
        print("\nLLM backend:")
        print("  [1] local llama.cpp + Qwen3.6 35B (recommended; ~12 GB download)")
        print("  [2] hosted OpenAI-compatible endpoint (LM Studio, Ollama, OpenAI, …)")
        let choice = promptUser("Choose [1]:").trimmingCharacters(in: .whitespacesAndNewlines)
        switch choice.isEmpty ? "1" : choice {
        case "1":
            try Backend.ensureLlamacpp()
            try Backend.downloadModel()
            try Backend.writeLocal()
        case "2":
            try await BackendHosted().execute()
        default:
            throw SiftError("invalid choice: \(choice)")
        }
    }

}
