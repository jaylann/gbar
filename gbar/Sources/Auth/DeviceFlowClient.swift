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
        var waitNanos = UInt64(max(code.interval, 1)) * 1_000_000_000
        let deadline = ContinuousClock.now.advanced(by: .seconds(code.expiresIn))

        while ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: waitNanos)
            let body = [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
            let (data, _) = try await post(url, form: body)
            let decoded = try jsonDecoder().decode(TokenResponse.self, from: data)
            if let token = decoded.accessToken { return token }
            switch decoded.error {
            case "authorization_pending": continue
            case "slow_down": waitNanos += UInt64(decoded.interval ?? 5) * 1_000_000_000
            case "expired_token": throw DeviceFlowError.expiredToken
            case "access_denied": throw DeviceFlowError.accessDenied
            case let other?: throw DeviceFlowError.unexpected(other)
            case nil: throw DeviceFlowError.unexpected("empty response")
            }
        }
        throw DeviceFlowError.expiredToken
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
