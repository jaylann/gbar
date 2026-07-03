import XCTest
@testable import gbar

/// Store-level coverage of `addAccountViaDeviceFlow` — the orchestration that used to live in
/// `AccountsPane`. The device-flow HTTP legs run through a real `DeviceFlowClient` on a mocked
/// session (via the `makeDeviceFlowClient` seam); tokens land in an in-memory box, and the
/// resulting account is validated against `FakeGitHubAPI.currentUser`.
@MainActor
final class AppStoreAddAccountTests: XCTestCase {
    private func makeStore(api: FakeGitHubAPI, accounts: [Account] = []) throws -> (AppStore, TokenBox) {
        let url = try XCTUnwrap(URL(string: "https://api.github.com"))
        let store = AppStore(apiBaseURL: url, accounts: accounts, makeAPI: { _, _ in api })
        let box = TokenBox()
        store.storeToken = { token, key in box.set(token, key) }
        store.tokenForAccount = { box.get($0.keychainKey) }
        store.deleteToken = { _ in }
        store.makeDeviceFlowClient = { clientID, webBaseURL in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            return DeviceFlowClient(
                clientID: clientID,
                webBaseURL: webBaseURL,
                session: URLSession(configuration: config)
            )
        }
        return (store, box)
    }

    /// Answers the device-code request, then the token poll — the two legs of the flow.
    private func stubDeviceFlowSuccess(token: String = "gho_new") {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let json = if url.path.hasSuffix("/login/device/code") {
                """
                {
                  "device_code": "device-123",
                  "user_code": "ABCD-1234",
                  "verification_uri": "https://github.com/login/device",
                  "interval": 0,
                  "expires_in": 30
                }
                """
            } else {
                #"{"access_token": "\#(token)"}"#
            }
            return (response, Data(json.utf8))
        }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testDeviceFlowAddsOAuthAccountAndStoresToken() async throws {
        let fake = FakeGitHubAPI()
        let (store, box) = try makeStore(api: fake)
        stubDeviceFlowSuccess()
        let codeBox = HandedCodeBox()

        try await store.addAccountViaDeviceFlow(
            clientID: "client-id",
            apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com")),
            openURL: { codeBox.openedURL = $0 },
            onUserCode: { codeBox.userCode = $0 }
        )

        // The pane got the code to render, and the browser was pointed at the verification page.
        XCTAssertEqual(codeBox.userCode, "ABCD-1234")
        XCTAssertEqual(codeBox.openedURL?.absoluteString, "https://github.com/login/device")
        // The account was registered as OAuth with its token in the (fake) Keychain slot.
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.login, "octocat")
        XCTAssertEqual(account.kind, .oauth)
        XCTAssertEqual(box.get(account.keychainKey), "gho_new")
        XCTAssertTrue(store.isSignedIn)
    }

    func testDeviceFlowFailureThrowsAndAddsNoAccount() async throws {
        let fake = FakeGitHubAPI()
        let (store, _) = try makeStore(api: fake)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let json = if url.path.hasSuffix("/login/device/code") {
                """
                {
                  "device_code": "device-123",
                  "user_code": "ABCD-1234",
                  "verification_uri": "https://github.com/login/device",
                  "interval": 0,
                  "expires_in": 30
                }
                """
            } else {
                #"{"error": "access_denied"}"#
            }
            return (response, Data(json.utf8))
        }

        do {
            try await store.addAccountViaDeviceFlow(
                clientID: "client-id",
                apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com")),
                openURL: { _ in },
                onUserCode: { _ in }
            )
            XCTFail("Expected the denied flow to throw")
        } catch let error as DeviceFlowClient.DeviceFlowError {
            XCTAssertEqual(error, .accessDenied)
        }

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(store.isSignedIn)
    }

    // MARK: - addAccount validation

    func testAddAccountInvalidTokenThrowsAndStoresNothing() async throws {
        let fake = FakeGitHubAPI(error: GitHubClient.ClientError.http(401))
        let (store, _) = try makeStore(api: fake)
        do {
            try await store.addAccount(
                token: "bad",
                kind: .personalAccessToken,
                apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com"))
            )
            XCTFail("Expected an invalid token to throw")
        } catch {}
        // currentUser() fails before storeToken, so nothing is connected or persisted.
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(store.isSignedIn)
    }

    func testAddAccountDuplicateLoginReplacesInPlace() async throws {
        var fake = FakeGitHubAPI()
        fake.currentUserResult = GitHubUser(login: "dup", avatarURL: nil)
        let (store, box) = try makeStore(api: fake)
        let url = try XCTUnwrap(URL(string: "https://api.github.com"))

        try await store.addAccount(token: "t1", kind: .personalAccessToken, apiBaseURL: url)
        try await store.addAccount(token: "t2", kind: .oauth, apiBaseURL: url)

        // Same login+host → same account id → replaced in place, newer metadata + token win.
        XCTAssertEqual(store.accounts.count, 1)
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.kind, .oauth)
        XCTAssertEqual(box.get(account.keychainKey), "t2")
    }

    // MARK: - In-place 401 reconnect

    private func expiredOAuthStore() throws -> (AppStore, TokenBox, Account) {
        var fake = FakeGitHubAPI()
        fake.currentUserResult = GitHubUser(login: "octocat", avatarURL: nil)
        let url = try XCTUnwrap(URL(string: "https://api.github.com"))
        let account = Account(login: "octocat", avatarURL: nil, kind: .oauth, apiBaseURL: url)
        let (store, box) = try makeStore(api: fake, accounts: [account])
        box.set("old-token", account.keychainKey)
        store.oauthClientID = "client-id"
        store.markSessionExpired(accountID: account.id)
        return (store, box, account)
    }

    func testReconnectReplacesTokenInPlaceAndClearsExpiry() async throws {
        let (store, box, account) = try expiredOAuthStore()
        stubDeviceFlowSuccess(token: "gho_reconnected")
        XCTAssertTrue(store.canReconnect)

        await store.reconnect(openURL: { _ in })

        // Same keychain slot → identity preserved; expiry cleared; status back to idle.
        XCTAssertEqual(box.get(account.keychainKey), "gho_reconnected")
        XCTAssertEqual(store.reauthStatus, .idle)
        XCTAssertFalse(store.sessionExpired)
        XCTAssertNil(store.expiredAccountID)
    }

    func testReconnectReentrancyGuardIgnoresSecondCall() async throws {
        let (store, _, _) = try expiredOAuthStore()
        store.reauthStatus = .starting // a reconnect is already in flight
        let handed = HandedCodeBox()
        // No MockURLProtocol handler installed: had the guard failed, the flow would hit the network.
        await store.reconnect(openURL: { handed.openedURL = $0 })

        XCTAssertNil(handed.openedURL)
        XCTAssertEqual(store.reauthStatus, .starting)
    }

    func testReconnectFailureSetsFailedStatusAndKeepsExpiry() async throws {
        let (store, box, account) = try expiredOAuthStore()
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let json = url.path.hasSuffix("/login/device/code")
                ? #"{"device_code":"d","user_code":"AB-12","verification_uri":"https://github.com/login/device","interval":0,"expires_in":30}"#
                : #"{"error":"access_denied"}"#
            return (response, Data(json.utf8))
        }

        await store.reconnect(openURL: { _ in })

        if case .failed = store.reauthStatus {} else {
            XCTFail("Expected .failed, got \(store.reauthStatus)")
        }
        // The old token is untouched and the account stays expired for another attempt.
        XCTAssertEqual(box.get(account.keychainKey), "old-token")
        XCTAssertTrue(store.sessionExpired)
        XCTAssertEqual(store.expiredAccountID, account.id)
    }

    func testPATPathValidatesTokenViaCurrentUser() async throws {
        var fake = FakeGitHubAPI()
        fake.currentUserResult = GitHubUser(login: "patuser", avatarURL: nil)
        let (store, box) = try makeStore(api: fake)

        try await store.addAccount(
            token: "ghp_pat",
            kind: .personalAccessToken,
            apiBaseURL: XCTUnwrap(URL(string: "https://api.github.com"))
        )

        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.login, "patuser")
        XCTAssertEqual(account.kind, .personalAccessToken)
        XCTAssertEqual(box.get(account.keychainKey), "ghp_pat")
    }
}

/// Captures the pane-facing callbacks (`onUserCode`, `openURL`) for assertion.
private final class HandedCodeBox {
    var userCode: String?
    var openedURL: URL?
}

/// In-memory Keychain stand-in (same shape as the one in `AppStoreTests`).
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.withLock { storage[key] }
    }

    func set(_ value: String, _ key: String) {
        lock.withLock { storage[key] = value }
    }
}
