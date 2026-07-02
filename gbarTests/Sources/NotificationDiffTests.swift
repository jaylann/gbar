import XCTest
@testable import gbar

/// Unit tests for the pure, account-aware `NotificationDiff` set math. State (baselines,
/// seeding, toggles) lives in `AppStore` and is covered by `AppStoreNotificationTests`.
final class NotificationDiffTests: XCTestCase {
    private func account(_ login: String = "octocat", host: String = "https://api.github.com") throws -> Account {
        try Account(login: login, avatarURL: nil, kind: .oauth, apiBaseURL: XCTUnwrap(URL(string: host)))
    }

    private func note(_ acct: Account, _ notification: GitHubNotification) -> AccountNotification {
        AccountNotification(account: acct, notification: notification)
    }

    private func item(_ acct: Account, _ issue: SearchIssue) -> AccountItem {
        AccountItem(account: acct, issue: issue)
    }

    // MARK: - Inbox

    func testNewNotificationsReturnsOnlyUnseenUnreadThreads() throws {
        let a = try account()
        let current = [
            note(a, .stub(id: "1", unread: true)),
            note(a, .stub(id: "2", unread: true)),
            note(a, .stub(id: "3", unread: false)), // read — never notified
        ]
        let previous: Set = [NotificationDiff.inboxKey(account: a, notification: .stub(id: "1"))]

        let new = NotificationDiff.newNotifications(previousUnreadKeys: previous, current: current)

        XCTAssertEqual(new.map(\.notification.id), ["2"]) // 1 already seen, 3 is read
    }

    func testNewNotificationsReNotifiesAThreadThatBecameUnreadAgain() throws {
        let a = try account()
        // Thread "5" was read last poll (not in the unread baseline) and is unread now.
        let current = [note(a, .stub(id: "5", unread: true))]

        let new = NotificationDiff.newNotifications(previousUnreadKeys: [], current: current)

        XCTAssertEqual(new.map(\.notification.id), ["5"])
    }

    func testNewNotificationsScopesKeysByAccount() throws {
        let alice = try account("alice")
        let bob = try account("bob")
        // The same thread id "1" is unread on both accounts; only alice's is already seen.
        let current = [note(alice, .stub(id: "1", unread: true)), note(bob, .stub(id: "1", unread: true))]
        let previous: Set = [NotificationDiff.inboxKey(account: alice, notification: .stub(id: "1"))]

        let new = NotificationDiff.newNotifications(previousUnreadKeys: previous, current: current)

        XCTAssertEqual(new.map(\.account.login), ["bob"]) // bob's "1" is not the same key as alice's
    }

    func testUnreadKeysTracksOnlyUnreadThreads() throws {
        let a = try account()
        let notes: [GitHubNotification] = [
            .stub(id: "1", unread: true),
            .stub(id: "2", unread: false),
            .stub(id: "3", unread: true),
        ]

        XCTAssertEqual(
            NotificationDiff.unreadKeys(account: a, notifications: notes),
            [
                NotificationDiff.inboxKey(account: a, notification: .stub(id: "1")),
                NotificationDiff.inboxKey(account: a, notification: .stub(id: "3")),
            ]
        )
    }

    // MARK: - Sections

    func testNewSectionItemsFindsUnseenKeysAndDedupesAcrossSections() throws {
        let a = try account()
        // id 2 repeats (as if across sections); id 3 is new; id 1 already seen.
        let items = [item(a, .stub(id: 1)), item(a, .stub(id: 2)), item(a, .stub(id: 2)), item(a, .stub(id: 3))]
        let previous: Set = [NotificationDiff.sectionItemKey(account: a, issue: .stub(id: 1))]

        let new = NotificationDiff.newSectionItems(previousKeys: previous, items: items)

        XCTAssertEqual(new.map(\.issue.id), [2, 3]) // 1 seen; 2 deduped to a single entry
    }

    func testSectionItemKeyScopesByAccount() throws {
        let alice = try account("alice")
        let bob = try account("bob")

        XCTAssertNotEqual(
            NotificationDiff.sectionItemKey(account: alice, issue: .stub(id: 1)),
            NotificationDiff.sectionItemKey(account: bob, issue: .stub(id: 1))
        )
    }

    // MARK: - CI status

    func testCheckStatusChangedNotifiesOnPendingToSuccess() {
        XCTAssertTrue(NotificationDiff.checkStatusChanged(previous: .pending, new: .success))
    }

    func testCheckStatusChangedNotifiesOnSuccessToFailure() {
        XCTAssertTrue(NotificationDiff.checkStatusChanged(previous: .success, new: .failure))
    }

    func testCheckStatusChangedIgnoresUnchangedTerminalStatus() {
        XCTAssertFalse(NotificationDiff.checkStatusChanged(previous: .success, new: .success))
    }

    func testCheckStatusChangedIgnoresFirstObservation() {
        // No prior status → first time we've seen this PR's CI; stay quiet.
        XCTAssertFalse(NotificationDiff.checkStatusChanged(previous: nil, new: .failure))
    }

    func testCheckStatusChangedIgnoresNonTerminalNewStatus() {
        XCTAssertFalse(NotificationDiff.checkStatusChanged(previous: .success, new: .pending))
    }
}
