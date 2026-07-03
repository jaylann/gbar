import Foundation
import Security

/// Minimal Keychain wrapper for a single secret string per key (generic password).
///
/// Prefers the **data-protection keychain** (`kSecUseDataProtectionKeychain`), whose access
/// is governed by the app's access-group entitlement rather than a per-item ACL. A
/// team-signed build therefore never shows the "gbar wants to use your confidential
/// information" prompt, and the grant survives rebuilds — unlike the file-based keychain,
/// whose ACL is bound to the app's code-signing Designated Requirement and re-prompts
/// whenever the signature changes (e.g. every ad-hoc rebuild).
///
/// A teamless ad-hoc build has no access group, so the data-protection keychain returns
/// `errSecMissingEntitlement`; we transparently fall back to the file-based keychain there.
/// That build still gets the ACL prompt, which is unavoidable without a signing team.
enum KeychainStore {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    private static let service = "dev.lanfermann.gbar"

    static func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let status = withKeychain { useDataProtection in
            var query = baseQuery(for: key, useDataProtection: useDataProtection)
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func get(_ key: String) -> String? {
        var item: CFTypeRef?
        let status = withKeychain(retryingNotFound: true) { useDataProtection in
            var query = baseQuery(for: key, useDataProtection: useDataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        // Purge both keychains unconditionally. A token written by an earlier teamless
        // (file-based) build must not survive logout once the build is team-signed — there
        // `withKeychain` never falls back (data-protection delete doesn't return
        // errSecMissingEntitlement), so a status-gated fallback would leave it behind.
        SecItemDelete(baseQuery(for: key, useDataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(for: key, useDataProtection: false) as CFDictionary)
    }

    // MARK: - Helpers

    private static func baseQuery(for key: String, useDataProtection: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: useDataProtection,
        ]
    }

    /// Whether a failed data-protection op should retry against the file keychain.
    /// `errSecMissingEntitlement` always retries (teamless build, no access group). Reads also
    /// retry on `errSecItemNotFound` so a value written via the file-keychain fallback (#53) is
    /// still found when the data-protection query answers "not found". Writes must NOT retry on
    /// not-found — an `SecItemAdd` returning not-found never means "the item is elsewhere".
    static func shouldRetryOnFileKeychain(_ status: OSStatus, retryingNotFound: Bool) -> Bool {
        status == errSecMissingEntitlement || (retryingNotFound && status == errSecItemNotFound)
    }

    /// Runs `op` against the data-protection keychain first; if the build carries no
    /// access-group entitlement (teamless ad-hoc → `errSecMissingEntitlement`), retries the
    /// same op against the file-based keychain so self-host builds keep working. Reads pass
    /// `retryingNotFound: true` so an `errSecItemNotFound` from the data-protection query also
    /// retries the file keychain — otherwise a token written via the fallback reads back nil (#53).
    private static func withKeychain(retryingNotFound: Bool = false,
                                     _ op: (_ useDataProtection: Bool) -> OSStatus) -> OSStatus {
        let status = op(true)
        guard shouldRetryOnFileKeychain(status, retryingNotFound: retryingNotFound) else { return status }
        return op(false)
    }
}
