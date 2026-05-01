import Foundation

public struct ServerPreset: Sendable, Hashable, Codable {
    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    public static let all: [ServerPreset] = [
        ServerPreset(name: "OCCRP Aleph",      url: "https://aleph.occrp.org"),
        ServerPreset(name: "Library of Leaks", url: "https://search.libraryofleaks.org"),
        ServerPreset(name: "OpenAleph",        url: "https://openaleph.org"),
    ]
}
