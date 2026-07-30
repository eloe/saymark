import XCTest
@testable import LiveInsertionPolicy

final class LiveInsertionPolicyTests: XCTestCase {
    func testInitialPolicyPinsApprovedStabilityAndTailLimits() {
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.matchingHypotheses, 2)
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.minimumTailAgeMilliseconds, 160)
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.maximumTailUTF16Length, 64)
        XCTAssertEqual(HypothesisStabilityPolicy.liveInsertion.maximumRevisionDepthWords, 4)
    }

    func testStableCandidateDoesNotCommitUntilCurrentGenerationAcknowledgement() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("hello", at: 0)
        let stable = tracker.ingest("hello", at: 160)

        XCTAssertEqual(stable.committedPrefix, "")
        XCTAssertEqual(stable.stableCandidatePrefix, "hello")
        let request = tryUnwrap(tracker.beginStableMutation())
        XCTAssertEqual(request.candidatePrefix, "hello")
        XCTAssertTrue(tracker.acknowledge(request.receipt))
        XCTAssertEqual(tracker.ingest("hello", at: 161).committedPrefix, "hello")
    }

    func testStaleAcknowledgementCannotCommitAfterCandidateChanges() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        let request = tryUnwrap(tracker.beginStableMutation())

        _ = tracker.ingest("omega", at: 170)

        XCTAssertFalse(tracker.acknowledge(request.receipt))
        XCTAssertEqual(tracker.ingest("omega", at: 171).committedPrefix, "")
    }

    func testCommittedPrefixRetractionFreezesPersistentlyUntilExplicitReset() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation()).receipt))

        XCTAssertEqual(tracker.ingest("omega", at: 170).phase, .frozenFinal)
        XCTAssertEqual(tracker.ingest("alpha again", at: 1_000).phase, .frozenFinal)

        tracker.resetForNewSession()
        XCTAssertEqual(tracker.ingest("omega", at: 0).phase, .live)
    }

    func testUnicodePunctuationWhitespaceAndUTF16RangesRemainExact() {
        let original = "  Привет,  🌍\n\tこんにちは — café  "
        var tracker = StableTranscriptTracker(policy: HypothesisStabilityPolicy(
            matchingHypotheses: 2,
            minimumTailAgeMilliseconds: 160,
            maximumTailUTF16Length: 64,
            maximumRevisionDepthWords: 10
        ))
        _ = tracker.ingest(original, at: 0)
        let update = tracker.ingest(original, at: 160)

        XCTAssertEqual(update.stableCandidatePrefix, original)
        XCTAssertEqual(update.revisableTail, original)
        XCTAssertEqual(update.revisableTail.utf16.count, original.utf16.count)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation()).receipt))
        XCTAssertEqual(tracker.ingest(original, at: 161).committedPrefix, original)
    }

    func testRetractionMayChangeOnlyUnacknowledgedRevisableTail() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation()).receipt))

        _ = tracker.ingest("alpha beta", at: 170)
        let update = tracker.ingest("alpha better", at: 180)

        XCTAssertEqual(update.committedPrefix, "alpha")
        XCTAssertEqual(update.revisableTail, " better")
        XCTAssertEqual(update.phase, .live)
    }

    func testThrottleFreezesFieldResidentCommittedAndTailAndMovesLaterContentToHUD() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        let tailRequest = tryUnwrap(tracker.beginStableMutation())
        XCTAssertTrue(tracker.acknowledge(tailRequest.receipt))

        let oversized = "alpha " + String(repeating: "x", count: 65)
        let throttled = tracker.ingest(oversized, at: 170)
        XCTAssertEqual(throttled.phase, .tailThrottled)
        XCTAssertEqual(throttled.committedPrefix, "alpha")
        XCTAssertEqual(throttled.revisableTail, "alpha")
        XCTAssertEqual(throttled.hudOnlyTail, oversized)

        let later = tracker.ingest("alpha replacement", at: 999)
        XCTAssertEqual(later.phase, .tailThrottled)
        XCTAssertEqual(later.committedPrefix, "alpha")
        XCTAssertEqual(later.revisableTail, "alpha")
        XCTAssertEqual(later.hudOnlyTail, "alpha replacement")
        XCTAssertNil(tracker.beginStableMutation())
    }

    func testMonotonicClockRollbackCannotPrematurelyStabilize() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("hello", at: 1_000)
        let rollback = tracker.ingest("hello", at: -500)
        XCTAssertEqual(rollback.stableCandidatePrefix, "")
        let tooSoon = tracker.ingest("hello", at: 1_159)
        XCTAssertEqual(tooSoon.stableCandidatePrefix, "")
        XCTAssertEqual(tracker.ingest("hello", at: 1_160).stableCandidatePrefix, "hello")
    }

    func testGenerationGateRejectsConcurrentAndStaleCompletion() {
        var gate = MutationGenerationGate()
        let first = tryUnwrap(gate.beginMutation())
        XCTAssertNil(gate.beginMutation())
        gate.invalidate()
        XCTAssertFalse(gate.complete(first))
        XCTAssertTrue(gate.complete(tryUnwrap(gate.beginMutation())))
    }

    func testSealedStopRoutingNeverFallsBackAfterAcknowledgedTailWrite() {
        var session = SealedLiveInsertionSession()
        session.recordAcknowledgedTailWrite()
        session.throttle()
        XCTAssertEqual(session.stop(ownershipVerified: false), .frozenFinal)
        XCTAssertEqual(session.stop(ownershipVerified: true), .noOp)
        XCTAssertEqual(session.state, .frozenFinalDelivered)
    }

    func testSecureTransitionWithTailSealsFrozenInsteadOfFallback() {
        var session = SealedLiveInsertionSession()
        session.recordAcknowledgedTailWrite()
        session.secureInputActivated()
        XCTAssertEqual(session.state, .secureFinal)
        XCTAssertEqual(session.stop(ownershipVerified: true), .copyOnly)
        XCTAssertEqual(session.stop(ownershipVerified: true), .noOp)
    }

    func testSecureInputDominatesFrozenOwnershipLossAndDeliversCopyOnlyOnce() {
        var session = SealedLiveInsertionSession()
        session.recordAcknowledgedTailWrite()
        session.invalidateOwnership()
        XCTAssertEqual(session.state, .frozenFinal)

        session.secureInputActivated()
        XCTAssertEqual(session.state, .secureFinal)
        XCTAssertEqual(session.stop(ownershipVerified: true), .copyOnly)
        XCTAssertEqual(session.stop(ownershipVerified: false), .noOp)
    }

    func testNoTailRoutesToFallbackExactlyOnceAndResetIsExplicit() {
        var session = SealedLiveInsertionSession()
        XCTAssertEqual(session.stop(ownershipVerified: false), .fallbackFinal)
        XCTAssertEqual(session.state, .fallbackFinalDelivered)
        XCTAssertEqual(session.stop(ownershipVerified: true), .noOp)
        session.resetForNewSession()
        XCTAssertEqual(session.state, .activeNoTail)
    }

    func testOwnedTailSettlementIsDeliveredExactlyOnce() {
        var session = SealedLiveInsertionSession()
        session.recordAcknowledgedTailWrite()

        XCTAssertEqual(session.stop(ownershipVerified: true), .settleOwnedTail)
        XCTAssertEqual(session.stop(ownershipVerified: true), .noOp)
        XCTAssertEqual(session.state, .settled)
    }

    /// Regression for the seed-81 schedule: a stop can be serialized before a
    /// later tracker acknowledgement. That acknowledgement did not create an
    /// owned session tail, so it must not be used to reinterpret the earlier
    /// fallback as an owned-tail fallback.
    func testSeed81DelayedAcknowledgementCannotRetroactivelyOwnDeliveredFallback() {
        var tracker = StableTranscriptTracker()
        var session = SealedLiveInsertionSession()

        XCTAssertEqual(session.stop(ownershipVerified: false), .fallbackFinal)

        let text = "stable-81"
        _ = tracker.ingest(text, at: 810)
        _ = tracker.ingest(text, at: 970)
        let request = tryUnwrap(tracker.beginStableMutation())
        XCTAssertTrue(tracker.acknowledge(request.receipt))
        XCTAssertFalse(session.recordAcknowledgedTailWrite())

        XCTAssertEqual(session.stop(ownershipVerified: true), .noOp)
        XCTAssertEqual(session.state, .fallbackFinalDelivered)
    }

    func testSecureInputNeverRoutesToFallbackEvenWithoutATail() {
        var active = SealedLiveInsertionSession()
        active.secureInputActivated()
        XCTAssertEqual(active.state, .secureFinal)
        XCTAssertEqual(active.stop(ownershipVerified: true), .copyOnly)
        XCTAssertEqual(active.stop(ownershipVerified: true), .noOp)

        var throttled = SealedLiveInsertionSession()
        throttled.throttle()
        throttled.secureInputActivated()
        XCTAssertEqual(throttled.state, .secureFinal)
        XCTAssertEqual(throttled.stop(ownershipVerified: false), .copyOnly)
    }

    func testOwnershipInvalidationIsTerminalEvenIfCallerTriesToContinue() {
        var session = SealedLiveInsertionSession()
        session.invalidateOwnership()
        session.recordAcknowledgedTailWrite()
        session.throttle()
        XCTAssertEqual(session.stop(ownershipVerified: true), .frozenFinal)
        XCTAssertEqual(session.stop(ownershipVerified: true), .noOp)
    }

    func testSliceOneClassifierNeverGrantsMutationAuthority() {
        let good = LeaseCapabilityInput(
            accessibilityTrusted: true, focusedEditableTarget: true, collapsedSelection: true,
            safeRole: true, rangedReadAvailable: true, secureRole: false,
            secureInputEnabled: false, terminalOrUncertified: false
        )
        XCTAssertEqual(SliceOneLeaseClassifier.classify(good), .evidenceOnlyCandidate)
        XCTAssertFalse(SliceOneLeaseClassifier.classify(good).deliveryPolicy.mayIssueExternalMutation)

        var protected = good
        protected.secureInputEnabled = true
        XCTAssertEqual(SliceOneLeaseClassifier.classify(protected), .protected)
        XCTAssertFalse(SliceOneLeaseClassifier.classify(protected).deliveryPolicy.mayIssueExternalMutation)

        var terminal = good
        terminal.terminalOrUncertified = true
        XCTAssertEqual(SliceOneLeaseClassifier.classify(terminal), .atomicFinalOnly)
    }

    func testAllDeliveryPoliciesDenyExternalMutationInSliceOne() {
        XCTAssertFalse(DeliveryPolicy.efficient.mayIssueExternalMutation)
        XCTAssertFalse(DeliveryPolicy.hudOnly.mayIssueExternalMutation)
        XCTAssertFalse(DeliveryPolicy.atomicFinal.mayIssueExternalMutation)
        XCTAssertFalse(DeliveryPolicy.protected.mayIssueExternalMutation)
        XCTAssertFalse(DeliveryPolicy.evidenceOnlyLiveCandidate.mayIssueExternalMutation)
    }

    func testLatestWinsBufferIsBoundedAndKeepsOnlyNewestWork() {
        var buffer = LatestWinsBuffer<Int>()
        for value in 0 ..< 100_000 { buffer.replace(with: value) }
        XCTAssertEqual(buffer.takeLatest(), 99_999)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testNormalEligibleUpdateScheduleKeepsRetainedPolicyStateBounded() {
        var tracker = StableTranscriptTracker()
        for value in 0 ..< 10_000 {
            let update = tracker.ingest("word-\(value % 100)", at: value)
            XCTAssertEqual(update.phase, .live)
            XCTAssertLessThanOrEqual(tracker.retainedUTF16Length, 64)
        }
    }

    func testSliceOneValuesCrossASendableConcurrencyBoundary() async {
        let result = await Task.detached { () -> (Bool, LiveInsertionStopRoute) in
            var buffer = LatestWinsBuffer<String>()
            buffer.replace(with: "latest")
            var session = SealedLiveInsertionSession()
            session.recordAcknowledgedTailWrite()
            return (buffer.takeLatest() == "latest", session.stop(ownershipVerified: false))
        }.value

        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, .frozenFinal)
    }

    func testLongSessionScheduleIsBoundedAndNeverRevivesAfterInvalidation() {
        var tracker = StableTranscriptTracker()
        for value in 0 ..< 10_000 {
            _ = tracker.ingest("word \(value)", at: value)
        }
        tracker.invalidateOwnership()
        for value in 10_000 ..< 20_000 {
            XCTAssertEqual(tracker.ingest("word \(value)", at: value).phase, .frozenFinal)
        }
    }

    func testMutationReceiptRejectsStaleGenerationAndMayNotBeReused() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        let alpha = tryUnwrap(tracker.beginStableMutation())
        // A newer recogniser observation retires every in-flight receipt,
        // including one whose text would otherwise still match.
        _ = tracker.ingest("alpha", at: 161)
        XCTAssertFalse(tracker.acknowledge(alpha.receipt))

        let current = tryUnwrap(tracker.beginStableMutation())
        XCTAssertTrue(tracker.acknowledge(current.receipt))
        XCTAssertFalse(tracker.acknowledge(current.receipt))
    }

    func testMutationReceiptRejectsArbitraryOrOversizeObservedTail() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        let request = tryUnwrap(tracker.beginStableMutation())

        XCTAssertFalse(tracker.acknowledge(request.receipt(observedTail: "omega")))
        XCTAssertFalse(tracker.acknowledge(request.receipt(observedTail: String(repeating: "x", count: 65))))
        XCTAssertTrue(tracker.acknowledge(request.receipt))
    }

    func testExactUTF16IdentityRejectsCanonicalLookalikes() {
        let decomposed = "e\u{301}"
        let composed = "\u{00E9}"
        XCTAssertEqual(decomposed, composed) // Swift's normal equality is not sufficient here.

        var tracker = StableTranscriptTracker()
        _ = tracker.ingest(decomposed, at: 0)
        _ = tracker.ingest(decomposed, at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation()).receipt))
        XCTAssertEqual(tracker.ingest(composed, at: 161).phase, .frozenFinal)
    }

    func testSeparatorMigrationAndTrailingWhitespaceKeepExactAcknowledgedPrefix() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation()).receipt))

        let migrated = tracker.ingest("alpha \t", at: 161)
        XCTAssertEqual(migrated.phase, .live)
        XCTAssertEqual(migrated.committedPrefix, "alpha")
        XCTAssertEqual(migrated.revisableTail, " \t")
        XCTAssertFalse(migrated.committedPrefix.utf16.elementsEqual("alpha \t".utf16))
    }

    func testOversizedHypothesisThrottlesWithoutRetainingUnboundedPolicyState() {
        var tracker = StableTranscriptTracker()
        let veryLong = String(repeating: "x", count: 1_000_000)
        let update = tracker.ingest(veryLong, at: 0)

        XCTAssertEqual(update.phase, .tailThrottled)
        XCTAssertLessThanOrEqual(tracker.retainedUTF16Length, 64)
    }

    func testConcurrentSchedulesInterleaveAllSliceOneEventsWithoutBreakingInvariants() async {
        actor Harness {
            struct Snapshot: Sendable {
                let trackerIsFrozen: Bool
                let deliveryCount: Int
                let ownedTailRoutedToFallback: Bool
                let bufferHasExactlyOneLatestValue: Bool
                let retiredGateStayedRetired: Bool
            }

            var tracker = StableTranscriptTracker()
            var session = SealedLiveInsertionSession()
            var buffer = LatestWinsBuffer<Int>()
            var retirementGate = MutationGenerationGate(nextSerialForTesting: UInt64.max - 1)
            var routes: [LiveInsertionStopRoute] = []
            var ownedTailSeen = false
            var retirementVerified = false

            func run(operation: Int, seed: Int) {
                switch operation % 7 {
                case 0: // ingest
                    _ = tracker.ingest("word-\(seed % 100)", at: seed)
                case 1: // acknowledgement handshake
                    let text = "stable-\(seed % 100)"
                    _ = tracker.ingest(text, at: seed * 10)
                    _ = tracker.ingest(text, at: seed * 10 + 160)
                    if let request = tracker.beginStableMutation(), tracker.acknowledge(request.receipt) {
                        // The tracker acknowledgement can arrive after a
                        // terminal stop in an interleaved test schedule. Only
                        // a session that accepted the hand-off owns a tail.
                        ownedTailSeen = session.recordAcknowledgedTailWrite() || ownedTailSeen
                    }
                case 2: // throttle
                    session.throttle()
                case 3: // secure input
                    session.secureInputActivated()
                case 4: // stop
                    routes.append(session.stop(ownershipVerified: seed.isMultiple(of: 2)))
                case 5: // ownership invalidation
                    tracker.invalidateOwnership()
                    session.invalidateOwnership()
                default: // latest-wins overflow and counter retirement
                    for offset in 0 ..< 100 { buffer.replace(with: seed * 100 + offset) }
                    _ = retirementGate.beginMutation()
                    retirementGate.invalidate()
                    retirementVerified = retirementGate.beginMutation() == nil
                }
            }

            func snapshot() -> Snapshot {
                let terminal = tracker.ingest("must-stay-frozen", at: Int.max).phase == .frozenFinal
                let delivered = routes.filter { $0 != .noOp }.count
                let fallbackAfterOwnedTail = ownedTailSeen && routes.contains(.fallbackFinal)
                let latest = buffer.takeLatest()
                let exactlyOneLatest = latest != nil && buffer.takeLatest() == nil
                let stillRetired = retirementVerified && retirementGate.beginMutation() == nil
                return Snapshot(
                    trackerIsFrozen: terminal,
                    deliveryCount: delivered,
                    ownedTailRoutedToFallback: fallbackAfterOwnedTail,
                    bufferHasExactlyOneLatestValue: exactlyOneLatest,
                    retiredGateStayedRetired: stillRetired
                )
            }
        }

        for seed in 0 ..< 500 {
            let harness = Harness()
            await withTaskGroup(of: Void.self) { group in
                for operation in 0 ..< 14 {
                    group.addTask { await harness.run(operation: operation + seed, seed: seed) }
                }
            }
            // End every schedule with invalidation so the terminal invariant is
            // deterministic while preceding operations remain task-interleaved.
            await harness.run(operation: 5, seed: seed)
            await harness.run(operation: 6, seed: seed)
            let result = await harness.snapshot()
            XCTAssertTrue(result.trackerIsFrozen, "seed \(seed)")
            XCTAssertLessThanOrEqual(result.deliveryCount, 1, "seed \(seed)")
            XCTAssertFalse(result.ownedTailRoutedToFallback, "seed \(seed)")
            XCTAssertTrue(result.bufferHasExactlyOneLatestValue, "seed \(seed)")
            XCTAssertTrue(result.retiredGateStayedRetired, "seed \(seed)")
        }
    }

    func testGenerationGateRetiresInsteadOfWrapping() {
        var gate = MutationGenerationGate(nextSerialForTesting: UInt64.max - 1)
        XCTAssertNotNil(gate.beginMutation())
        gate.invalidate()
        XCTAssertNil(gate.beginMutation())
    }

    func testReliabilityPropertySchedulesNeverRouteOwnedTailToFallback() {
        for seed in 0 ..< 1_000 {
            var session = SealedLiveInsertionSession()
            var owned = false
            for step in 0 ..< 10 {
                switch (seed + step * 17) % 5 {
                case 0: session.recordAcknowledgedTailWrite(); owned = true
                case 1: session.throttle()
                case 2: session.secureInputActivated()
                case 3: session.invalidateOwnership()
                default: break
                }
            }
            let route = session.stop(ownershipVerified: seed.isMultiple(of: 2))
            if owned { XCTAssertNotEqual(route, .fallbackFinal, "seed \(seed)") }
        }
    }

    func testTenThousandDeterministicTerminalSchedulesDeliverAtMostOnce() {
        for seed in 0 ..< 10_000 {
            var session = SealedLiveInsertionSession()
            for step in 0 ..< 8 {
                switch (seed &+ step &* 31) % 6 {
                case 0: session.recordAcknowledgedTailWrite()
                case 1: session.throttle()
                case 2: session.secureInputActivated()
                case 3: session.invalidateOwnership()
                default: break
                }
            }
            _ = session.stop(ownershipVerified: seed.isMultiple(of: 2))
            XCTAssertEqual(session.stop(ownershipVerified: !seed.isMultiple(of: 2)), .noOp, "seed \(seed)")
        }
    }

    func testClosedTelemetryUsesOnlyBuckets() {
        let event = LiveInsertionTelemetry(
            outcome: .tailThrottled,
            tailLength: .bucket(for: 65),
            revisionDepth: .bucket(for: 4)
        )
        XCTAssertEqual(event.tailLength, .sixtyFiveToOneTwentyEight)
        XCTAssertEqual(event.revisionDepth, .oneToFour)
    }

    #if SAYMARK_POLICY_PERFORMANCE
    /// Deliberately excluded from ordinary unit runs. Invoke through
    /// Scripts/benchmark-live-insertion-policy.sh on the recorded release
    /// machine; wall-clock thresholds are an acceptance measurement, not a
    /// portable correctness assertion.
    func testOptInNormalPolicyUpdatePerformanceAcceptance() {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        samples.reserveCapacity(10_000)

        for value in 0 ..< 10_000 {
            var tracker = StableTranscriptTracker()
            _ = tracker.ingest("alpha \(value)", at: 0)
            let start = clock.now
            _ = tracker.ingest("alpha \(value)", at: 160)
            samples.append(start.duration(to: clock.now))
        }

        let sorted = samples.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        XCTAssertLessThanOrEqual(p95, .milliseconds(1))
        XCTAssertLessThanOrEqual(sorted.last!, .milliseconds(5))
    }
    #endif

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("expected non-nil", file: file, line: line)
            fatalError("test continuation")
        }
        return value
    }
}
