import Foundation

/// Lenient decoding of the persisted accounts blob. Split out of `AppStore` (which is at its
/// SwiftLint `file_length` budget) — the logic is pure and static, so it composes cleanly here.
extension AppStore {
    /// Decode the persisted accounts blob **leniently**: skip any malformed element instead of
    /// dropping the whole list. A strict `[Account].self` decode fails the entire array on one bad
    /// element (e.g. a field a newer build added, or a corrupt entry), silently signing the user
    /// out of every account and orphaning their Keychain tokens. Decoding element-wise keeps the
    /// good accounts and logs how many were dropped. Returns empty if the blob isn't a JSON array.
    static func decodePersistedAccounts(from data: Data) -> [Account] {
        do {
            let decoded = try JSONDecoder().decode([FailableDecodable<Account>].self, from: data)
            let accounts = decoded.compactMap(\.value)
            let dropped = decoded.count - accounts.count
            if dropped > 0 {
                Log.store.error("accounts decode dropped \(dropped, privacy: .public) malformed element(s)")
            }
            return accounts
        } catch {
            Log.store.error("accounts decode failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// Decodes `T`, capturing a per-element decode failure as `nil` rather than aborting the whole
/// container — so one corrupt element in a persisted array can't drop every sibling.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}
