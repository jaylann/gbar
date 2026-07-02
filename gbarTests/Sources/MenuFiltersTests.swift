import XCTest
@testable import gbar

/// The Inbox filter chips match GitHub's raw REST `reason` strings — pin that mapping so a
/// renamed case can't silently stop filtering.
final class MenuFiltersTests: XCTestCase {
    func testAllMatchesEveryReason() {
        for raw in ["review_requested", "mention", "assign", "subscribed", "author", ""] {
            XCTAssertTrue(InboxReason.all.matches(raw), "expected .all to match \(raw)")
        }
    }

    func testReviewRequestedMatchesOnlyItsRawReason() {
        XCTAssertTrue(InboxReason.reviewRequested.matches("review_requested"))
        XCTAssertFalse(InboxReason.reviewRequested.matches("mention"))
        // The display name is not the wire name — must not match.
        XCTAssertFalse(InboxReason.reviewRequested.matches("reviewRequested"))
    }

    func testMentionedMatchesOnlyItsRawReason() {
        XCTAssertTrue(InboxReason.mentioned.matches("mention"))
        XCTAssertFalse(InboxReason.mentioned.matches("team_mention"))
        XCTAssertFalse(InboxReason.mentioned.matches("assign"))
    }

    func testAssignedMatchesOnlyItsRawReason() {
        XCTAssertTrue(InboxReason.assigned.matches("assign"))
        XCTAssertFalse(InboxReason.assigned.matches("assigned"))
        XCTAssertFalse(InboxReason.assigned.matches("review_requested"))
    }
}
