import XCTest
@testable import SaymarkKit

final class DictationUpdateHubTests: XCTestCase {
    func test_multipleSubscribersReceiveTheSameUpdate() {
        let hub = DictationUpdateHub()
        var first: [(String, String)] = []
        var second: [(String, String)] = []
        let firstSubscription = hub.subscribe { first.append(($0, $1)) }
        let secondSubscription = hub.subscribe { second.append(($0, $1)) }

        hub.publish(confirmed: "final", partial: "draft")

        XCTAssertEqual(first.map(\.0), ["final"])
        XCTAssertEqual(first.map(\.1), ["draft"])
        XCTAssertEqual(second.map(\.0), ["final"])
        XCTAssertEqual(second.map(\.1), ["draft"])
        withExtendedLifetime((firstSubscription, secondSubscription)) {}
    }

    func test_cancellingOneSubscriberDoesNotAffectAnother() {
        let hub = DictationUpdateHub()
        var firstCount = 0
        var secondCount = 0
        let first = hub.subscribe { _, _ in firstCount += 1 }
        let second = hub.subscribe { _, _ in secondCount += 1 }

        first.cancel()
        hub.publish(confirmed: "hello", partial: "")

        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
        withExtendedLifetime(second) {}
    }

    func test_subscriptionAutomaticallyCancelsOnRelease() {
        let hub = DictationUpdateHub()
        var count = 0
        var subscription: DictationUpdateSubscription? = hub.subscribe { _, _ in count += 1 }
        XCTAssertNotNil(subscription)

        subscription = nil
        hub.publish(confirmed: "hello", partial: "")

        XCTAssertEqual(count, 0)
    }
}
