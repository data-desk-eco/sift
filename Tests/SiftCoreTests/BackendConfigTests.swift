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
