import XCTest
@testable import SaymarkKit

final class FinalAudioBufferTests: XCTestCase {
    func testAdmissionBudgetBoundsQueuedAndTotalAudio() {
        var budget = CaptureAdmissionBudget(maximumTotalSamples: 10, maximumQueuedSamples: 6)

        XCTAssertEqual(budget.reserve(4), .init(acceptedCount: 4, newStopReason: nil))
        XCTAssertEqual(budget.reserve(3), .init(acceptedCount: 0, newStopReason: .backlogOverload))
        XCTAssertEqual(budget.totalAcceptedSamples, 4)
        XCTAssertEqual(budget.queuedSamples, 4)
        XCTAssertEqual(budget.stopReason, .backlogOverload)
        XCTAssertEqual(budget.reserve(1).acceptedCount, 0)
    }

    func testAdmissionBudgetAcceptsFinalPrefixThenSignalsDurationLimitOnce() {
        var budget = CaptureAdmissionBudget(maximumTotalSamples: 5, maximumQueuedSamples: 5)

        XCTAssertEqual(budget.reserve(3), .init(acceptedCount: 3, newStopReason: nil))
        budget.complete(3)
        XCTAssertEqual(budget.reserve(4), .init(acceptedCount: 2, newStopReason: .maximumDuration))
        XCTAssertEqual(budget.totalAcceptedSamples, 5)
        XCTAssertEqual(budget.reserve(1), .init(acceptedCount: 0, newStopReason: nil))
    }

    func testAdmissionBudgetLatchesTerminalCaptureFailure() {
        var budget = CaptureAdmissionBudget(maximumTotalSamples: 10, maximumQueuedSamples: 10)

        XCTAssertTrue(budget.terminate(.captureFailure))
        XCTAssertFalse(budget.terminate(.backlogOverload))
        XCTAssertEqual(budget.stopReason, .captureFailure)
        XCTAssertEqual(budget.reserve(1), .init(acceptedCount: 0, newStopReason: nil))
    }

    func testCaptureStopRequestMatchesOnlyItsSession() {
        let request = CaptureStopRequest(sessionID: "current", generation: 7, reason: .maximumDuration)

        XCTAssertTrue(request.belongs(to: "current"))
        XCTAssertFalse(request.belongs(to: "next"))
        XCTAssertFalse(request.belongs(to: nil))
    }

    func testFinalAudioOverflowFailsClosedWithoutRetainingPastBound() {
        var buffer = FinalAudioBuffer(maximumSamples: 5)
        buffer.append([1, 2, 3, 4], speechDetected: true)
        buffer.append([5, 6, 7], speechDetected: true)

        XCTAssertEqual(buffer.sampleCount, 5)
        XCTAssertNil(buffer.takeIfSpeechDetected())
        XCTAssertEqual(buffer.sampleCount, 0)
    }

    func testDefaultBufferDoesNotInheritMicrophoneDurationLimit() {
        var buffer = FinalAudioBuffer()
        let samples = Array(repeating: Float(0.25), count: MicCapture.maximumUtteranceSamples + 1)

        buffer.append(samples, speechDetected: true)

        XCTAssertEqual(buffer.takeIfSpeechDetected()?.count, samples.count)
    }
    func testLeadingAudioIsPreservedWhenSpeechIsDetectedLater() {
        var buffer = FinalAudioBuffer()
        buffer.append([1, 2, 3], speechDetected: false)
        buffer.append([4, 5], speechDetected: true)

        XCTAssertEqual(buffer.takeIfSpeechDetected(), [1, 2, 3, 4, 5])
    }

    func testAllSilenceSkipsFinalInferenceAndClearsAudio() {
        var buffer = FinalAudioBuffer()
        buffer.append([1, 2, 3], speechDetected: false)

        XCTAssertNil(buffer.takeIfSpeechDetected())
        XCTAssertEqual(buffer.sampleCount, 0)
    }

    func testTakeResetsSpeechStateForTheNextUtterance() {
        var buffer = FinalAudioBuffer()
        buffer.append([1], speechDetected: true)
        XCTAssertEqual(buffer.takeIfSpeechDetected(), [1])

        buffer.append([2], speechDetected: false)
        XCTAssertNil(buffer.takeIfSpeechDetected())
    }
}
