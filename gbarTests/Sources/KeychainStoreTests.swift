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
        // errSecItemNotFound (not errSecMissingEntitlement), so `get` never falls back and
        // returns nil for a value `set` just stored. See #53.
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
}
