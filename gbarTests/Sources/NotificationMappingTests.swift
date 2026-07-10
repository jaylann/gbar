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
        let api = try XCTUnwrap(URL(string: "https://api.github.com"))
        let url = try XCTUnwrap(notification.htmlURL(apiBaseURL: api))
        XCTAssertEqual(url.absoluteString, "https://github.com/octo/repo/pull/1")
    }

    func testHTMLURLUsesEnterpriseWebHost() throws {
        let notification = GitHubNotification.stub(
            id: "1",
            type: "PullRequest",
            repo: "octo/repo",
            subjectURL: "https://ghe.example.com/api/v3/repos/octo/repo/pulls/7"
        )
        let api = try XCTUnwrap(URL(string: "https://ghe.example.com/api/v3"))
        let url = try XCTUnwrap(notification.htmlURL(apiBaseURL: api))
        // Enterprise: web host is scheme+host of the API base, and the `/api/v3` prefix is
        // dropped — not string-replaced against a hardcoded `api.github.com`.
        XCTAssertEqual(url.absoluteString, "https://ghe.example.com/octo/repo/pull/7")
    }

    func testHTMLURLMapsIssueSubject() throws {
        let notification = GitHubNotification.stub(
            id: "1",
            type: "Issue",
            repo: "octo/repo",
            subjectURL: "https://api.github.com/repos/octo/repo/issues/5"
        )
        let api = try XCTUnwrap(URL(string: "https://api.github.com"))
        let url = try XCTUnwrap(notification.htmlURL(apiBaseURL: api))
        XCTAssertEqual(url.absoluteString, "https://github.com/octo/repo/issues/5")
    }

    /// Only the resource-type segment is rewritten: a repo literally named "pulls" must survive.
    /// A naive `replacingOccurrences(of: "/pulls/", …)` over the whole tail would corrupt the repo
    /// segment; the component-wise mapping touches only position 2.
    func testHTMLURLRewritesOnlyResourceSegment() throws {
        let notification = GitHubNotification.stub(
            id: "1",
            type: "PullRequest",
            repo: "octo/pulls",
            subjectURL: "https://api.github.com/repos/octo/pulls/pulls/3"
        )
        let api = try XCTUnwrap(URL(string: "https://api.github.com"))
        let url = try XCTUnwrap(notification.htmlURL(apiBaseURL: api))
        XCTAssertEqual(url.absoluteString, "https://github.com/octo/pulls/pull/3")
    }

    func testHTMLURLIsNilWhenSubjectURLMissing() throws {
        let notification = GitHubNotification.stub(id: "1", subjectURL: nil)
        let api = try XCTUnwrap(URL(string: "https://api.github.com"))
        XCTAssertNil(notification.htmlURL(apiBaseURL: api))
    }
}
