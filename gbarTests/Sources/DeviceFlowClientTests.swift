import XCTest
@testable import gbar

/// Exercises the OAuth device-flow actor over `MockURLProtocol` — request-code decoding,
/// the poll loop's GitHub error grammar (`authorization_pending` / `slow_down` /
/// `access_denied` / `expired_token`), and the expiry deadline. No real network.
final class DeviceFlowClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient() throws -> DeviceFlowClient {
        try DeviceFlowClient(
            clientID: "test-client-id",
            webBaseURL: XCTUnwrap(URL(string: "https://github.com")),
            session: makeSession()
        )
    }

    /// A device code polling at the client's 1-second floor (`max(interval, 1)`), expiring far
    /// enough out that the loop is driven by the mocked responses, not the deadline. Each poll
    /// therefore sleeps a real second — the multi-poll tests cost ~2s wall-clock apiece.
    private func makeCode(expiresIn: Int = 30) -> DeviceFlowClient.DeviceCode {
        .init(
            deviceCode: "device-123",
            userCode: "ABCD-1234",
            verificationUri: "https://github.com/login/device",
            interval: 0,
            expiresIn: expiresIn
        )
    }

    private static func ok(_ request: URLRequest, json: String) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (response, Data(json.utf8))
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - requestDeviceCode

    func testRequestDeviceCodeDecodesSnakeCaseResponse() async throws {
        let box = RequestBox()
        MockURLProtocol.handler = { request in
            box.path = request.url?.path
            box.body = request.formBody
            return try Self.ok(request, json: """
            {
              "device_code": "device-123",
              "user_code": "ABCD-1234",
              "verification_uri": "https://github.com/login/device",
              "interval": 5,
              "expires_in": 900
            }
            """)
        }

        let code = try await makeClient().requestDeviceCode(scopes: DeviceFlowClient.defaultScopes)

        XCTAssertEqual(code.deviceCode, "device-123")
        XCTAssertEqual(code.userCode, "ABCD-1234")
        XCTAssertEqual(code.verificationUri, "https://github.com/login/device")
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(code.expiresIn, 900)
        XCTAssertEqual(box.path, "/login/device/code")
        let body = try XCTUnwrap(box.body)
        XCTAssertTrue(body.contains("client_id=test-client-id"))
        XCTAssertTrue(body.contains("repo"))
        XCTAssertTrue(body.contains("notifications"))
    }

    func testRequestDeviceCodeMapsNon200ToHTTPError() async throws {
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
            )
            return (response, Data())
        }

        do {
            _ = try await makeClient().requestDeviceCode(scopes: ["repo"])
            XCTFail("Expected requestDeviceCode to throw")
        } catch let error as DeviceFlowClient.DeviceFlowError {
            XCTAssertEqual(error, .http(404))
        }
    }

    func testRequestDeviceCodeMalformedJSONThrowsDecodingError() async throws {
        MockURLProtocol.handler = { request in
            try Self.ok(request, json: #"{"nope": true}"#)
        }

        do {
            _ = try await makeClient().requestDeviceCode(scopes: ["repo"])
            XCTFail("Expected requestDeviceCode to throw")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - pollForToken

    func testPollForTokenReturnsTokenAfterPending() async throws {
        let counter = CallCounter()
        MockURLProtocol.handler = { request in
            switch counter.next() {
            case 1: try Self.ok(request, json: #"{"error": "authorization_pending"}"#)
            default: try Self.ok(request, json: #"{"access_token": "gho_token"}"#)
            }
        }

        let token = try await makeClient().pollForToken(makeCode())

        XCTAssertEqual(token, "gho_token")
        XCTAssertEqual(counter.count, 2)
    }

    func testPollForTokenHonorsSlowDownThenSucceeds() async throws {
        let counter = CallCounter()
        MockURLProtocol.handler = { request in
            switch counter.next() {
            // interval 0 keeps the ADDED back-off at zero (the 1s poll floor still applies);
            // the branch under test is "slow_down keeps polling instead of throwing".
            case 1: try Self.ok(request, json: #"{"error": "slow_down", "interval": 0}"#)
            default: try Self.ok(request, json: #"{"access_token": "gho_token"}"#)
            }
        }

        let token = try await makeClient().pollForToken(makeCode())

        XCTAssertEqual(token, "gho_token")
        XCTAssertEqual(counter.count, 2)
    }

    func testPollForTokenAccessDeniedThrows() async {
        MockURLProtocol.handler = { request in
            try Self.ok(request, json: #"{"error": "access_denied"}"#)
        }

        await assertPollThrows(.accessDenied)
    }

    func testPollForTokenExpiredTokenThrows() async {
        MockURLProtocol.handler = { request in
            try Self.ok(request, json: #"{"error": "expired_token"}"#)
        }

        await assertPollThrows(.expiredToken)
    }

    func testPollForTokenUnknownErrorThrowsUnexpected() async {
        MockURLProtocol.handler = { request in
            try Self.ok(request, json: #"{"error": "unsupported_grant_type"}"#)
        }

        await assertPollThrows(.unexpected("unsupported_grant_type"))
    }

    func testPollForTokenEmptyResponseThrowsUnexpected() async {
        MockURLProtocol.handler = { request in
            try Self.ok(request, json: "{}")
        }

        await assertPollThrows(.unexpected("empty response"))
    }

    func testPollForTokenExpiresWithoutEverPolling() async {
        let counter = CallCounter()
        MockURLProtocol.handler = { request in
            _ = counter.next()
            return try Self.ok(request, json: #"{"error": "authorization_pending"}"#)
        }

        // An already-expired code must fail up front, before the first network poll.
        await assertPollThrows(.expiredToken, code: makeCode(expiresIn: 0))
        XCTAssertEqual(counter.count, 0)
    }

    private func assertPollThrows(
        _ expected: DeviceFlowClient.DeviceFlowError,
        code: DeviceFlowClient.DeviceCode? = nil
    ) async {
        do {
            _ = try await makeClient().pollForToken(code ?? makeCode())
            XCTFail("Expected pollForToken to throw")
        } catch let error as DeviceFlowClient.DeviceFlowError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

/// Captures request details out of the `@Sendable` mock handler (same shape as
/// `HeaderBox` in `GitHubClientTests`).
private final class RequestBox: @unchecked Sendable {
    var path: String?
    var body: String?
}

/// Thread-safe call counter for handlers that answer differently per poll.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

extension URLRequest {
    /// `URLProtocol` surfaces POST bodies as a stream, not `httpBody` — drain it.
    fileprivate var formBody: String? {
        guard let stream = httpBodyStream else { return httpBody.map { String(decoding: $0, as: UTF8.self) } }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
