import XCTest
@testable import gbar

/// Note: the poll *loop* itself isn't unit-tested here — driving it needs a fake `GitHubAPI`
/// injected into `AppStore.refresh()`, whose fetch body is intentionally untouched on this
/// branch. These tests cover the pure option model the Settings picker and persistence rely on.
final class PollIntervalTests: XCTestCase {
    func testOffIsZeroAndOthersPositive() {
        XCTAssertEqual(PollInterval.off.rawValue, 0)
        for interval in PollInterval.allCases where interval != .off {
            XCTAssertGreaterThan(interval.rawValue, 0)
        }
    }

    func testDefaultIntervalRoundTrips() {
        XCTAssertEqual(PollInterval(rawValue: 60), .m1)
    }

    func testAllCasesAndLabels() {
        XCTAssertEqual(PollInterval.allCases, [.off, .s30, .m1, .m5, .m15])
        for interval in PollInterval.allCases {
            XCTAssertFalse(interval.label.isEmpty)
        }
    }
}
