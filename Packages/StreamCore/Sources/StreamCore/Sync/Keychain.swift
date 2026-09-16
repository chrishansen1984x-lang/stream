import Foundation
import os
import Security

/// Minimal Keychain wrapper for OAuth tokens.
///
/// `UserDefaults` would have been fewer lines, but access and refresh tokens are
/// long-lived credentials that grant access to the user's Trakt account — they do
/// not belong in a plist that any process with file access can read.
/// Public because the app layer stores credentials too — the Screen device token
/// is held by `AppModel` rather than by a sync type of its own.
public enum Keychain {
    /// Stores a secret. An empty value is ignored, never written and never a wipe.
    ///
    /// Every secret here is bound straight to a `SecureField` whose `didSet`
    /// persists on each keystroke, and each is loaded as `Keychain.get(…) ?? ""`.
    /// So an empty string arrives in two ways that are both accidents: a field
    /// that commits before it has been filled in, and a read that failed at launch
    /// leaving the model holding "". Writing that through replaced a good token
    /// with an empty blob, silently — the only symptom being a feature that
    /// quietly stopped working, with the settings field still looking merely
    /// "not set up yet". Forgetting a secret on purpose goes through `clear(_:)`.
    @discardableResult
    public static func set(_ value: String?, for key: String) -> OSStatus {
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return errSecParam }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available after first unlock so background playback reporting still
            // works with the device locked, but never synced to other devices.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        // The status used to be discarded, which made a refused write look exactly
        // like a successful one. Callers decide what a failure means; this reports it.
        if status != errSecSuccess {
            logger.error("Keychain write for \(key, privacy: .public) failed: \(status)")
        }
        return status
    }

    private static let logger = Logger(subsystem: "com.stream.core", category: "Keychain")

    public static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // A refused read and an absent item both returned nil, and every caller
        // turns nil into "" — which reads as "not set up yet" for a credential that
        // is stored and merely unreadable. Read authorisation here is granted per
        // binary, so a copy of the app run from another path is when this bites.
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.error("Keychain read for \(key, privacy: .public) failed: \(status)")
            }
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Forgets a secret. The deliberate counterpart to `set`, which cannot.
    @discardableResult
    public static func clear(_ key: String) -> OSStatus { remove(key) }

    @discardableResult
    static func remove(_ key: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("Keychain delete for \(key, privacy: .public) failed: \(status)")
        }
        return status
    }

    private static let service = "com.stream.trakt"
}
