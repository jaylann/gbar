import XCTest
@testable import gbar

/// Records register/unregister calls and lets a test stub the reported state (and force a
/// failure), so the store's login-item logic is exercised without touching `SMAppService`.
@MainActor
final class SpyLaunchAtLogin: LaunchAtLoginManaging {
    var isEnabled = false
    var errorToThrow: Error?
    private(set) var setCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        setCalls.append(enabled)
        if let errorToThrow { throw errorToThrow }
        isEnabled = enabled
    }
}

@MainActor
final class AppStoreLaunchAtLoginTests: XCTestCase {
    private struct Boom: Error {}

    private func makeStore() throws -> AppStore {
        let url = try XCTUnwrap(URL(string: "https://api.github.com"))
        return AppStore(apiBaseURL: url, accounts: [], makeAPI: { _, _ in FakeGitHubAPI() })
    }

    func testSetLaunchAtLoginRegistersAndMirrors() throws {
        let store = try makeStore()
        let spy = SpyLaunchAtLogin()
        store.launchAtLogin = spy

        store.setLaunchAtLogin(true)

        XCTAssertEqual(spy.setCalls, [true])
        XCTAssertTrue(spy.isEnabled)
        XCTAssertTrue(store.launchAtLoginEnabled)
    }

    func testSetLaunchAtLoginUnregisters() throws {
        let store = try makeStore()
        let spy = SpyLaunchAtLogin()
        spy.isEnabled = true
        store.launchAtLogin = spy
        store.launchAtLoginEnabled = true

        store.setLaunchAtLogin(false)

        XCTAssertEqual(spy.setCalls, [false])
        XCTAssertFalse(spy.isEnabled)
        XCTAssertFalse(store.launchAtLoginEnabled)
    }

    /// A failed registration must leave the mirror at the OS's actual state, not the requested
    /// one, so the toggle snaps back instead of lying.
    func testSetLaunchAtLoginFailureResyncsToActualState() throws {
        let store = try makeStore()
        let spy = SpyLaunchAtLogin()
        spy.errorToThrow = Boom()
        store.launchAtLogin = spy

        store.setLaunchAtLogin(true)

        XCTAssertEqual(spy.setCalls, [true])
        XCTAssertFalse(spy.isEnabled) // setEnabled threw before flipping it
        XCTAssertFalse(store.launchAtLoginEnabled)
    }

    func testRefreshMirrorsServiceStatus() throws {
        let store = try makeStore()
        let spy = SpyLaunchAtLogin()
        spy.isEnabled = true
        store.launchAtLogin = spy

        store.refreshLaunchAtLoginStatus()

        XCTAssertTrue(store.launchAtLoginEnabled)
    }

    /// Without an injected service (tests/previews) both entry points are inert.
    func testNoServiceIsNoOp() throws {
        let store = try makeStore()

        store.setLaunchAtLogin(true)
        store.refreshLaunchAtLoginStatus()

        XCTAssertFalse(store.launchAtLoginEnabled)
    }
}
