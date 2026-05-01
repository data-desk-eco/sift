import Foundation
import LocalAuthentication
import Security

/// Real macOS Keychain wrapper. Generic password items in the user's
/// login keychain, scoped to the `eco.datadesk.sift` service.
///
/// Items are stored with a biometric access control: reads require Touch
/// ID instead of the legacy login-keychain password prompt. A shared
/// `LAContext` with the maximum allowable reuse duration deduplicates
/// successive reads inside the same process — so a single CLI invocation
/// that needs the vault passphrase + Aleph URL + Aleph key prompts the
/// user once, not three times.
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

    /// Single LAContext for the lifetime of the process; the reuse
    /// duration means we Touch-ID once and the OS releases subsequent
    /// reads to us automatically.
    private static let sharedContext: LAContext = {
        let ctx = LAContext()
        ctx.touchIDAuthenticationAllowableReuseDuration =
            LATouchIDAuthenticationMaximumAllowableReuseDuration
        return ctx
    }()

    private static func biometricACL() -> SecAccessControl? {
        var error: Unmanaged<CFError>?
        let acl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryAny,
            &error
        )
        if acl == nil, let e = error?.takeRetainedValue() {
            FileHandle.standardError.write(Data(
                "[keychain] biometric ACL unavailable: \(e)\n".utf8
            ))
        }
        return acl
    }

    /// Save under biometric ACL. We delete-then-add because
    /// `SecItemUpdate` won't refresh `kSecAttrAccessControl` on an
    /// already-stored item, leaving older non-biometric items in place.
    @discardableResult
    public static func set(_ key: String, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(identity as CFDictionary)

        var add = identity
        add[kSecValueData] = data
        if let acl = biometricACL() {
            add[kSecAttrAccessControl] = acl
        } else {
            // Fall back to the legacy accessibility key on hardware
            // without biometrics so we don't lock the user out.
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func get(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: sharedContext,
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

    /// Existence check that does NOT trigger a Touch ID prompt — we
    /// query the item's attributes (no `kSecReturnData`) with a context
    /// that disallows interaction, so the keychain reports presence
    /// without unlocking the secret.
    public static func has(_ key: String) -> Bool {
        let nonInteractive = LAContext()
        nonInteractive.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: nonInteractive,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecSuccess: present, no auth needed (legacy item).
        // errSecInteractionNotAllowed: present, biometric ACL — auth needed.
        // errSecItemNotFound: absent.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Enumerate every account name we've stored under this service.
    /// Returning attributes-only doesn't unlock the secret, so this is
    /// also Touch-ID-free.
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
