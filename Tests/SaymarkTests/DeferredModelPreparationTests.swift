import SaymarkKit
import XCTest
@testable import Saymark

final class DeferredModelPreparationTests: XCTestCase {
    func testRequestWhenLifecycleIsBusyRemainsPendingUntilReleased() {
        var preparation = DeferredModelPreparation()

        XCTAssertNil(preparation.request(.hybrid, canStartNow: false))
        XCTAssertEqual(preparation.pendingMode, .hybrid)
        XCTAssertNil(preparation.takePending(canStartNow: false))
        XCTAssertEqual(preparation.pendingMode, .hybrid)
    }

    func testDeferredRequestsAreLatestWins() {
        var preparation = DeferredModelPreparation()

        XCTAssertNil(preparation.request(.hybrid, canStartNow: false))
        XCTAssertNil(preparation.request(.accurate, canStartNow: false))
        XCTAssertNil(preparation.request(.hybrid, canStartNow: false))

        XCTAssertEqual(preparation.takePending(canStartNow: true), .hybrid)
        XCTAssertNil(preparation.takePending(canStartNow: true))
    }

    func testReadyRequestStartsImmediatelyWithoutLeavingStalePendingWork() {
        var preparation = DeferredModelPreparation()

        XCTAssertNil(preparation.request(.hybrid, canStartNow: false))
        XCTAssertEqual(preparation.request(.accurate, canStartNow: true), .accurate)
        XCTAssertNil(preparation.pendingMode)
        XCTAssertNil(preparation.takePending(canStartNow: true))
    }
}
