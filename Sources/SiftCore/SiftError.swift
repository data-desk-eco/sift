import Foundation

public struct SiftError: LocalizedError, Sendable {
    public let message: String
    public let suggestion: String

    public init(_ message: String, suggestion: String = "") {
        self.message = message
        self.suggestion = suggestion
    }

    public var errorDescription: String? {
        suggestion.isEmpty ? message : "\(message)\n  → \(suggestion)"
    }
}
