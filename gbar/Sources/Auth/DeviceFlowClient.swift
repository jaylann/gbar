import Foundation

/// GitHub OAuth **device flow** — the only auth path that needs no client secret and no
/// callback server, which is exactly why gbar can be self-hosted for free with just a
/// public client ID. See docs/SELF-HOST.md.
actor DeviceFlowClient {
    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let interval: Int
        let expiresIn: Int
    }

    enum DeviceFlowError: Error, Equatable {
        case http(Int)
        case authorizationPending
        case slowDown
        case expiredToken
        case accessDenied
        case unexpected(String)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let interval: Int?
    }

    /// Scopes gbar requests for a device-flow token: `repo` (PR/issue data + quick actions)
    /// and `notifications` (the inbox). Shared by the Settings sign-in and the in-place 401
    /// reconnect so both grants stay identical.
    static let defaultScopes = ["repo", "notifications"]

    let clientID: String
    /// Web host that serves the device-flow endpoints (github.com, or an Enterprise host).
    let webBaseURL: URL

    private let session: URLSession

    init(
        clientID: String,
        webBaseURL: URL = URL(string: "https://github.com") ?? URL(fileURLWithPath: "/"),
        session: URLSession = .shared
    ) {
        self.clientID = clientID
        self.webBaseURL = webBaseURL
        self.session = session
    }

    /// Step 1: ask GitHub for a device + user code to display to the user.
    func requestDeviceCode(scopes: [String]) async throws -> DeviceCode {
        let url = webBaseURL.appendingPathComponent("login/device/code")
        let body = ["client_id": clientID, "scope": scopes.joined(separator: " ")]
        let (data, response) = try await post(url, form: body)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DeviceFlowError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try jsonDecoder().decode(DeviceCode.self, from: data)
    }

    /// Step 2: poll until the user authorizes (or the code expires). Returns the token.
    func pollForToken(_ code: DeviceCode) async throws -> String {
        let url = webBaseURL.appendingPathComponent("login/oauth/access_token")
        var waitNanos = Self.backoffNanos(code.interval)
        let deadline = ContinuousClock.now.advanced(by: .seconds(code.expiresIn))

        while ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: waitNanos)
            let body = [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
            let (data, response) = try await post(url, form: body)
            // A transient 5xx or a 429 (or a proxy's non-JSON body behind either) would fail the
            // decode and abort the whole sign-in — keep polling instead. The device-flow error
            // states (`authorization_pending`/`slow_down`/…) arrive as JSON on 200 or 4xx, so decode
            // everything else.
            if let http = response as? HTTPURLResponse,
               http.statusCode == 429 || (500...599).contains(http.statusCode)
            {
                continue
            }
            let decoded = try jsonDecoder().decode(TokenResponse.self, from: data)
            if let token = decoded.accessToken { return token }
            switch decoded.error {
            case "authorization_pending": continue
            // GitHub's `slow_down` carries the *new* required interval (already increased), not a
            // delta — replace, don't accumulate, or repeated slow-downs compound and burn the
            // expiry window.
            case "slow_down": waitNanos = Self.backoffNanos(decoded.interval ?? 5)
            case "expired_token": throw DeviceFlowError.expiredToken
            case "access_denied": throw DeviceFlowError.accessDenied
            case let other?: throw DeviceFlowError.unexpected(other)
            case nil: throw DeviceFlowError.unexpected("empty response")
            }
        }
        throw DeviceFlowError.expiredToken
    }

    /// Poll back-off in nanoseconds, clamped to `[1, 60]` seconds so a hostile or garbage
    /// host-supplied interval can't overflow the `UInt64` multiply (or stall the loop for hours).
    private static func backoffNanos(_ interval: Int) -> UInt64 {
        UInt64(min(max(interval, 1), 60)) * 1_000_000_000
    }

    private func post(_ url: URL, form: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeForm(form)
        return try await session.data(for: request)
    }

    private func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func encodeForm(_ form: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}
