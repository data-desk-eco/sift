import Foundation
import Testing
@testable import SiftCore

@Suite(.serialized) struct BackendConfigTests {

    @Test func writeReadRoundTripsLocal() throws {
        try withTempHome { _ in
            try Backend.writeLocal()
            let config = try Backend.requireConfig()
            #expect(config.kind == .local)
            #expect(config.modelName == Backend.defaultModelName)
            #expect(config.port == Backend.defaultLocalPort)
        }
    }

    @Test func readReturnsNilWhenAbsent() {
        withTempHome { _ in
            #expect(Backend.readConfig() == nil)
        }
    }

    @Test func requireConfigThrowsWhenAbsent() {
        withTempHome { _ in
            #expect(throws: SiftError.self) {
                _ = try Backend.requireConfig()
            }
        }
    }

    @Test func configCodableSurvivesRoundtrip() throws {
        let original = Backend.Config.makeHosted(
            baseURL: "https://api.example.org/v1",
            modelName: "gpt-4o"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Backend.Config.self, from: data)
        #expect(decoded.kind == .hosted)
        #expect(decoded.baseURL == "https://api.example.org/v1")
        #expect(decoded.modelName == "gpt-4o")
        #expect(decoded.port == nil)
    }

    @Test func writeConfigSetsPosix600() throws {
        try withTempHome { _ in
            try Backend.writeLocal()
            let attrs = try FileManager.default.attributesOfItem(
                atPath: Backend.configPath.path
            )
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(perms == 0o600)
        }
    }

    @Test func kvCacheFilenameIncludesModelAndVersion() {
        // The filename llama-server's --slot-save-path writes to must
        // include both the model stem and the cache-format version, so
        // swapping models OR bumping the format silently invalidates
        // stale slots without us having to wipe the dir manually.
        let name = LlamaServer.kvCacheFilename(modelFile: "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf")
        #expect(name.contains("Qwen3_6-35B-A3B-UD-Q2_K_XL"))
        #expect(name.contains("v\(LlamaServer.kvCacheVersion)"))
        #expect(name.hasSuffix(".bin"))
    }

    @Test func kvCacheFilenamesDifferByModel() {
        // Two different model files must get different slot files —
        // otherwise restoring after a model swap would try to apply a
        // KV slot built for the wrong tensor shapes.
        let a = LlamaServer.kvCacheFilename(modelFile: "model-a.gguf")
        let b = LlamaServer.kvCacheFilename(modelFile: "model-b.gguf")
        #expect(a != b)
    }

    @Test func configurePiPointsLocalAtForgePort() throws {
        // Pi must hit the forge proxy port, not the llama-server port —
        // forge sits in front of llama-server on the local backend.
        try withTempHome { home in
            try Backend.writeLocal()
            try Backend.configurePi()

            let modelsPath = home.appending(path: "pi/models.json")
            let data = try Data(contentsOf: modelsPath)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let providers = json?["providers"] as? [String: Any]
            let sift = providers?["sift"] as? [String: Any]
            let baseURL = sift?["baseUrl"] as? String

            #expect(baseURL == "http://127.0.0.1:\(Backend.defaultProxyPort)/v1")
        }
    }
}
