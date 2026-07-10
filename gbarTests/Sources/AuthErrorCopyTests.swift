import Foundation
import XCTest
@testable import gbar

final class AuthErrorCopyTests: XCTestCase {
    // MARK: - Device-flow errors

    func testDeviceFlowExpiredTokenExplainsAndPromptsRestart() {
        let message = AuthErrorCopy.message(for: DeviceFlowClient.DeviceFlowError.expiredToken)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("expired"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("again"))
    }

    func testDeviceFlowAccessDeniedIsActionable() {
        let message = AuthErrorCopy.message(for: DeviceFlowClient.DeviceFlowError.accessDenied)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("denied"))
    }

    func testDeviceFlowUnexpectedIncludesDetail() {
        let message = AuthErrorCopy.message(for: DeviceFlowClient.DeviceFlowError.unexpected("weird_state"))
        XCTAssertTrue(message.contains("weird_state"))
    }

    func testDeviceFlowHTTPReusesSharedHTTPCopy() {
        let flow = AuthErrorCopy.message(for: DeviceFlowClient.DeviceFlowError.http(401))
        let client = AuthErrorCopy.message(for: GitHubClient.ClientError.http(401))
        XCTAssertEqual(flow, client)
    }

    // MARK: - Client errors

    func testUnauthorizedMentionsTheToken() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(401))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("token"))
    }

    func testForbiddenMentionsRateLimitOrScopes() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(403))
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("rate")
                || message.localizedCaseInsensitiveContains("scope")
        )
    }

    func testNotFoundPointsAtAPIBaseURL() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(404))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("base url"))
    }

    func testServerErrorAsksToRetryLater() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(503))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("try again"))
    }

    func testMethodNotAllowedExplainsMergeBlock() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(405))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("merge"))
        XCTAssertFalse(message.contains("405"))
    }

    func testConflictExplainsBranchChanged() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(409))
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("changed")
                || message.localizedCaseInsensitiveContains("conflict")
        )
        XCTAssertFalse(message.contains("409"))
    }

    func testUnprocessableExplainsRejection() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(422))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("rejected"))
        XCTAssertFalse(message.contains("422"))
    }

    func testUnhandledStatusIncludesCode() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(418))
        XCTAssertTrue(message.contains("418"))
    }

    func testBadURLPointsAtAdvanced() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.badURL)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("base url"))
    }

    func testRateLimitedWithResetNamesTheTime() {
        let until = Date().addingTimeInterval(600)
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.rateLimited(until: until))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("rate limited"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("retrying at"))
    }

    func testRateLimitedWithoutResetSaysShortly() {
        let message = AuthErrorCopy.rateLimitMessage(until: nil)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("rate limited"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("shortly"))
    }

    func testTooManyRequestsMentionsRateLimit() {
        let message = AuthErrorCopy.message(for: GitHubClient.ClientError.http(429))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("rate"))
    }

    // MARK: - Transport / fallback

    func testURLErrorReadsAsAConnectionProblem() {
        let message = AuthErrorCopy.message(for: URLError(.notConnectedToInternet))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("connection"))
    }

    func testUnknownErrorFallsBackToGenericCopy() {
        struct Boom: Error {}
        let message = AuthErrorCopy.message(for: Boom())
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("try again"))
    }
}
