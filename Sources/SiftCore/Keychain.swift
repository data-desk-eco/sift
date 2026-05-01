import Foundation
import Security

/// Real macOS Keychain wrapper. Generic password items in the user's
/// login keychain, scoped to the `eco.datadesk.sift` service.
///
/// Holds: vault passphrase, Aleph URL + API key, hosted-backend URL +
/// API key. Local-llama-cpp doesn't need a key — its config lives in
/// `~/.sift/backend.json` (no secrets).
public enum Keychain {
    public static let service = "eco.datadesk.sift"

    public enum Key {
        public static let vaultPassphrase  = "vault.passphrase"
        public static let alephURL         = "aleph.url"
        public static let alephAPIKey      = "aleph.api-key"
        public static let hostedBaseURL    = "backend.hosted.base-url"
        public static let hostedAPIKey     = "backend.hosted.api-key"
        public static let hostedModelName  = "backend.hosted.model-name"
    }

    @discardableResult
    public static func set(_ key: String, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]

        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert.merge(update) { $1 }
            let add = SecItemAdd(insert as CFDictionary, nil)
            return add == errSecSuccess
        }
        return false
    }

    public static func get(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    @discardableResult
    public static func delete(_ key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static func has(_ key: String) -> Bool {
        get(key) != nil
    }

    /// Enumerate every account name we've stored under this service.
    public static func keys() -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
