import XCTest
@testable import LiveInsertionPolicy

final class LiveInsertionPolicyTests: XCTestCase {
    func testInitialPolicyPinsApprovedStabilityAndTailLimits() {
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.matchingHypotheses, 2)
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.minimumTailAgeMilliseconds, 160)
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.maximumTailUTF16Length, 64)
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.maximumRevisionDepthWords, 4)
    }

    func testMatchingHypothesesCommitOnlyAfterAgeAndConfirmation() {
        var tracker = StableTranscriptTracker()

        XCTAssertEqual(tracker.ingest("hello", at: 0).committedPrefix, "")
        XCTAssertEqual(tracker.ingest("hello", at: 159).committedPrefix, "")

        let update = tracker.ingest("hello", at: 160)
        XCTAssertEqual(update.committedPrefix, "hello")
        XCTAssertEqual(update.revisableTail, "")
        XCTAssertEqual(update.phase, .live)
    }

    func testRetractionCanOnlyChangeRevisableTail() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        _ = tracker.ingest("alpha beta", at: 170)

        let update = tracker.ingest("alpha better", at: 180)

        XCTAssertEqual(update.committedPrefix, "alpha")
        XCTAssertEqual(update.revisableTail, "better")
        XCTAssertEqual(update.revisionDepthWords, 1)
    }

    func testAttemptToRetractCommittedPrefixFreezesInsteadOfRewritingIt() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)

        let update = tracker.ingest("omega", at: 170)

        XCTAssertEqual(update.phase, .frozenFinal)
        XCTAssertEqual(update.committedPrefix, "alpha")
        XCTAssertEqual(update.revisableTail, "")
    }

    func testPunctuationAndUnicodeRemainInsideTokenOwnership() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("Привет, 🌍", at: 0)
        let update = tracker.ingest("Привет, 🌍", at: 160)

        XCTAssertEqual(update.committedPrefix, "Привет, 🌍")
        XCTAssertEqual(update.revisableTail, "")
    }

    func testTailOverCapEntersThrottleAndCarriesExcessInHUDOnlyText() {
        var tracker = StableTranscriptTracker()
        let oversized = String(repeating: "a", count: 65)

        let update = tracker.ingest(oversized, at: 0)

        XCTAssertEqual(update.phase, .tailThrottled)
        XCTAssertEqual(update.revisableTail, "")
        XCTAssertEqual(update.hudOnlyTail, oversized)
    }

    func testThrottleSettlesOnlyWithVerifiedOwnershipAndOtherwiseFreezes() {
        XCTAssertEqual(
            LiveInsertionStopRouter.route(hasWrittenTail: true, ownershipVerified: true),
            .settleOwnedTail
        )
        XCTAssertEqual(
            LiveInsertionStopRouter.route(hasWrittenTail: true, ownershipVerified: false),
            .frozenFinal
        )
    }

    func testNoTailRoutesToFallbackEvenWhenSecureInputTransitions() {
        XCTAssertEqual(
            LiveInsertionStopRouter.route(hasWrittenTail: false, ownershipVerified: false),
            .fallbackFinal
        )
    }

    func testGenerationAndSingleInFlightOperationRejectStaleCompletion() {
        var gate = MutationGenerationGate()
        let first = gate.beginMutation()
        XCTAssertNotNil(first)
        XCTAssertNil(gate.beginMutation())

        gate.invalidate()
        XCTAssertFalse(gate.complete(first!))

        let second = gate.beginMutation()
        XCTAssertNotNil(second)
        XCTAssertTrue(gate.complete(second!))
    }

    func testNonLiveDeliveryModesNeverAuthorizeExternalMutation() {
        XCTAssertFalse(DeliveryPolicy.efficient.mayIssueExternalMutation)
        XCTAssertFalse(DeliveryPolicy.hudOnly.mayIssueExternalMutation)
        XCTAssertFalse(DeliveryPolicy.atomicFinal.mayIssueExternalMutation)
        XCTAssertFalse(DeliveryPolicy.protected.mayIssueExternalMutation)
        XCTAssertTrue(DeliveryPolicy.verifiedLive.mayIssueExternalMutation)
    }

    func testClosedTelemetryUsesBucketsAndNoFreeFormTargetIdentity() {
        let event = LiveInsertionTelemetry(
            outcome: .tailThrottled,
            tailLength: .bucket(for: 65),
            revisionDepth: .bucket(for: 4)
        )

        XCTAssertEqual(event.tailLength, .sixtyFiveToOneTwentyEight)
        XCTAssertEqual(event.revisionDepth, .oneToFour)
    }
}
