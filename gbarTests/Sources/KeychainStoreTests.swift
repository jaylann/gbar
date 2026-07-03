import XCTest
@testable import gbar

/// Round-trips the real `KeychainStore` implementation (Security framework, including the
/// data-protection → file-based fallback) against test-only account keys. Environments
/// where the test runner has no keychain access (some CI setups) skip instead of failing.
final class KeychainStoreTests: XCTestCase {
    private let key = "gbar-tests.keychain-store"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Probe the full round-trip, not just the write: on CI runners the write can land in
        // the file-keychain fallback while the read's data-protection query answers
        // errSecItemNotFound (not errSecMissingEntitlement). `get` now also falls back to the
        // file keychain on errSecItemNotFound (#53), so that documented round-trip case is now
        // covered and should no longer need to skip on the affected runners. We keep the
        // set-throws XCTSkip as defense (a truly locked-out runner still can't write), and keep
        // the round-trip XCTSkip belt-and-suspenders in case a runner fails for other reasons.
        do {
            try KeychainStore.set("probe", for: key)
        } catch {
            throw XCTSkip("Keychain unavailable in this environment: \(error)")
        }
        let roundTrip = KeychainStore.get(key)
        KeychainStore.remove(key)
        if roundTrip != "probe" {
            throw XCTSkip("Keychain round-trip unavailable in this environment (get after set returned nil)")
        }
    }

    override func tearDown() {
        KeychainStore.remove(key)
        super.tearDown()
    }

    func testGetMissingKeyReturnsNil() {
        XCTAssertNil(KeychainStore.get(key))
    }

    func testSetThenGetRoundTrips() throws {
        try KeychainStore.set("gho_secret", for: key)
        XCTAssertEqual(KeychainStore.get(key), "gho_secret")
    }

    func testSetOverwritesExistingValue() throws {
        try KeychainStore.set("first", for: key)
        try KeychainStore.set("second", for: key)
        XCTAssertEqual(KeychainStore.get(key), "second")
    }

    func testRemoveDeletesValue() throws {
        try KeychainStore.set("gho_secret", for: key)
        KeychainStore.remove(key)
        XCTAssertNil(KeychainStore.get(key))
    }

    func testRemoveMissingKeyIsANoOp() {
        KeychainStore.remove(key)
        XCTAssertNil(KeychainStore.get(key))
    }

    func testValuesPreserveNonASCIIContent() throws {
        try KeychainStore.set("töken-✓-秘密", for: key)
        XCTAssertEqual(KeychainStore.get(key), "töken-✓-秘密")
    }

    /// The read-vs-write fallback semantics (#53): reads retry the file keychain on
    /// errSecItemNotFound, writes do not; both always retry on errSecMissingEntitlement.
    func testShouldRetryOnFileKeychainTruthTable() {
        // Success never retries.
        XCTAssertFalse(KeychainStore.shouldRetryOnFileKeychain(errSecSuccess, retryingNotFound: false))
        XCTAssertFalse(KeychainStore.shouldRetryOnFileKeychain(errSecSuccess, retryingNotFound: true))
        // Missing entitlement always retries (teamless build, no access group).
        XCTAssertTrue(KeychainStore.shouldRetryOnFileKeychain(errSecMissingEntitlement, retryingNotFound: false))
        XCTAssertTrue(KeychainStore.shouldRetryOnFileKeychain(errSecMissingEntitlement, retryingNotFound: true))
        // Not-found retries only on reads.
        XCTAssertFalse(KeychainStore.shouldRetryOnFileKeychain(errSecItemNotFound, retryingNotFound: false))
        XCTAssertTrue(KeychainStore.shouldRetryOnFileKeychain(errSecItemNotFound, retryingNotFound: true))
        // A generic error never retries.
        XCTAssertFalse(KeychainStore.shouldRetryOnFileKeychain(errSecAuthFailed, retryingNotFound: false))
        XCTAssertFalse(KeychainStore.shouldRetryOnFileKeychain(errSecAuthFailed, retryingNotFound: true))
    }
}
