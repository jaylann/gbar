import XCTest
@testable import gbar

final class NotificationMappingTests: XCTestCase {
    func testReasonMapping() {
        XCTAssertEqual(NotificationRow.Model.reason(from: "review_requested"), .reviewRequested)
        XCTAssertEqual(NotificationRow.Model.reason(from: "mention"), .mention)
        XCTAssertEqual(NotificationRow.Model.reason(from: "assign"), .assigned)
        XCTAssertEqual(NotificationRow.Model.reason(from: "state_change"), .stateChange)
        XCTAssertEqual(NotificationRow.Model.reason(from: "comment"), .commented)
        // Unknown reasons fall back to a comment rather than failing.
        XCTAssertEqual(NotificationRow.Model.reason(from: "subscribed"), .commented)
    }

    func testSymbolMapping() {
        XCTAssertEqual(NotificationRow.Model.symbol(forSubjectType: "PullRequest"), "arrow.triangle.pull")
        XCTAssertEqual(NotificationRow.Model.symbol(forSubjectType: "Issue"), "smallcircle.circle")
        XCTAssertEqual(NotificationRow.Model.symbol(forSubjectType: "Release"), "bell")
    }

    func testModelMapsAllFields() {
        let notification = GitHubNotification.stub(
            id: "42",
            unread: false,
            reason: "mention",
            type: "Issue",
            repo: "jaylann/gbar",
            title: "Popover flickers"
        )

        let model = NotificationRow.Model(notification)

        XCTAssertEqual(model.id, "42")
        XCTAssertEqual(model.repo, "jaylann/gbar")
        XCTAssertEqual(model.title, "Popover flickers")
        XCTAssertEqual(model.reason, .mention)
        XCTAssertFalse(model.isUnread)
        XCTAssertEqual(model.symbol, "smallcircle.circle")
    }

    func testHTMLURLRewritesAPIURL() throws {
        let notification = GitHubNotification.stub(id: "1", type: "PullRequest", repo: "octo/repo")
        let url = try XCTUnwrap(notification.htmlURL)
        XCTAssertEqual(url.absoluteString, "https://github.com/octo/repo/pull/1")
    }
}
