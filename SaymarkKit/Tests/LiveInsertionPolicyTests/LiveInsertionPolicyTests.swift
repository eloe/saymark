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
        XCTAssertTrue(tracker.acknowledge(request))
        XCTAssertEqual(tracker.ingest("hello", at: 161).committedPrefix, "hello")
    }

    func testStaleAcknowledgementCannotCommitAfterCandidateChanges() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        let request = tryUnwrap(tracker.beginStableMutation())

        _ = tracker.ingest("omega", at: 170)

        XCTAssertFalse(tracker.acknowledge(request))
        XCTAssertEqual(tracker.ingest("omega", at: 171).committedPrefix, "")
    }

    func testCommittedPrefixRetractionFreezesPersistentlyUntilExplicitReset() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation())))

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
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation())))
        XCTAssertEqual(tracker.ingest(original, at: 161).committedPrefix, original)
    }

    func testRetractionMayChangeOnlyUnacknowledgedRevisableTail() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation())))

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
        XCTAssertTrue(tracker.acknowledge(tailRequest))
        XCTAssertTrue(tracker.acknowledgeFieldResidentTail(" beta", for: tailRequest))

        let oversized = "alpha " + String(repeating: "x", count: 65)
        let throttled = tracker.ingest(oversized, at: 170)
        XCTAssertEqual(throttled.phase, .tailThrottled)
        XCTAssertEqual(throttled.committedPrefix, "alpha")
        XCTAssertEqual(throttled.revisableTail, " beta")
        XCTAssertEqual(throttled.hudOnlyTail, oversized)

        let later = tracker.ingest("alpha replacement", at: 999)
        XCTAssertEqual(later.phase, .tailThrottled)
        XCTAssertEqual(later.committedPrefix, "alpha")
        XCTAssertEqual(later.revisableTail, " beta")
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

    func testNormalPolicyUpdateWorkMeetsSliceOneTimeBudget() {
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

    func testTailAcknowledgementRejectsStaleRequestOrGeneration() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        let alpha = tryUnwrap(tracker.beginStableMutation())
        XCTAssertTrue(tracker.acknowledge(alpha))

        // A subsequent hypothesis retires the acknowledgement receipt before a
        // coordinator can report an old field tail as current state.
        _ = tracker.ingest("alpha beta", at: 161)
        XCTAssertFalse(tracker.acknowledgeFieldResidentTail(" alpha", for: alpha))

        _ = tracker.ingest("alpha beta", at: 321)
        let beta = tryUnwrap(tracker.beginStableMutation())
        XCTAssertTrue(tracker.acknowledge(beta))
        XCTAssertFalse(tracker.acknowledgeFieldResidentTail(" beta", for: alpha))
        XCTAssertTrue(tracker.acknowledgeFieldResidentTail(" beta", for: beta))
        XCTAssertFalse(tracker.acknowledgeFieldResidentTail(" beta", for: beta))
    }

    func testExactUTF16IdentityRejectsCanonicalLookalikes() {
        let decomposed = "e\u{301}"
        let composed = "\u{00E9}"
        XCTAssertEqual(decomposed, composed) // Swift's normal equality is not sufficient here.

        var tracker = StableTranscriptTracker()
        _ = tracker.ingest(decomposed, at: 0)
        _ = tracker.ingest(decomposed, at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation())))
        XCTAssertEqual(tracker.ingest(composed, at: 161).phase, .frozenFinal)
    }

    func testSeparatorMigrationAndTrailingWhitespaceKeepExactAcknowledgedPrefix() {
        var tracker = StableTranscriptTracker()
        _ = tracker.ingest("alpha", at: 0)
        _ = tracker.ingest("alpha", at: 160)
        XCTAssertTrue(tracker.acknowledge(tryUnwrap(tracker.beginStableMutation())))

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

    func testConcurrentSchedulesSerialiseInvalidationAndNeverReviveTracker() async {
        actor Harness {
            var tracker = StableTranscriptTracker()
            func ingest(_ text: String, _ time: Int) -> LiveInsertionPhase {
                tracker.ingest(text, at: time).phase
            }
            func invalidate() { tracker.invalidateOwnership() }
        }

        let harness = Harness()
        await withTaskGroup(of: Void.self) { group in
            for value in 0 ..< 500 {
                group.addTask { _ = await harness.ingest("word \(value)", value) }
            }
            group.addTask { await harness.invalidate() }
        }
        let terminalPhase = await harness.ingest("later", 1_000)
        XCTAssertEqual(terminalPhase, .frozenFinal)
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

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("expected non-nil", file: file, line: line)
            fatalError("test continuation")
        }
        return value
    }
}
