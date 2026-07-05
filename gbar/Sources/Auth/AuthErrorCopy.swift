import Foundation

/// Maps low-level auth failures (`DeviceFlowClient.DeviceFlowError`, `GitHubClient.ClientError`,
/// transport errors) to a single friendly, actionable line for the sign-in / reconnect UI.
///
/// Pure and UI-free so it's unit-testable and reusable from both the Settings sign-in flow and
/// the in-place 401 reconnect prompt.
enum AuthErrorCopy {
    /// Best-effort friendly message for any error thrown along an auth path.
    static func message(for error: Error) -> String {
        switch error {
        case let flow as DeviceFlowClient.DeviceFlowError:
            message(forDeviceFlow: flow)
        case let client as GitHubClient.ClientError:
            message(forClient: client)
        case is URLError:
            "Couldn't reach GitHub. Check your connection and try again."
        default:
            "Sign-in failed. Please try again."
        }
    }

    static func message(forDeviceFlow error: DeviceFlowClient.DeviceFlowError) -> String {
        switch error {
        case .authorizationPending:
            "Still waiting for you to authorize gbar in the browser…"
        case .slowDown:
            "GitHub asked us to slow down — still waiting for authorization…"
        case .expiredToken:
            "The code expired before you authorized it. Start again to get a new code."
        case .accessDenied:
            "Authorization was denied. Try again and approve gbar to continue."
        case let .http(code):
            httpMessage(code)
        case let .unexpected(detail):
            "GitHub returned an unexpected response (\(detail)). Try again."
        }
    }

    static func message(forClient error: GitHubClient.ClientError) -> String {
        switch error {
        case let .http(code): httpMessage(code)
        case .badURL: "That API base URL looks invalid — check it under Advanced."
        case let .rateLimited(until): rateLimitMessage(until: until)
        // The batch hydration catches `.graphQL` and falls back to REST, so it never reaches
        // user-facing copy; map it to the generic message defensively.
        case .graphQL: "Something went wrong talking to GitHub. Try again."
        }
    }

    /// Copy for a rate-limited state, naming the retry time when GitHub told us one.
    static func rateLimitMessage(until: Date?) -> String {
        guard let until, until > Date() else {
            return "Rate limited by GitHub — retrying shortly."
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Rate limited by GitHub — retrying at \(formatter.string(from: until))."
    }

    /// Shared copy for an HTTP status, so device-flow and REST failures speak the same language.
    private static func httpMessage(_ code: Int) -> String {
        switch code {
        case 401:
            "That token was rejected. Check it hasn't expired and has the required scopes (repo, notifications)."
        case 403:
            "GitHub refused the request — you may be rate-limited or the token is missing scopes. Try again later."
        case 429:
            "GitHub rate-limited the request. Try again in a little while."
        case 404:
            "GitHub couldn't find that endpoint. Check the API base URL for your host under Advanced."
        case 500...599:
            "GitHub is having trouble right now. Try again in a moment."
        default:
            "GitHub returned an error (HTTP \(code)). Try again."
        }
    }
}
