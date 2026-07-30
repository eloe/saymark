import XCTest
@testable import SaymarkKit

final class CaptureStartupRollbackTests: XCTestCase {
    private struct StartFailure: Error {}

    func testStartFailureRollsBackExactlyOnceBeforeEscaping() {
        var events: [String] = []

        XCTAssertThrowsError(
            try CaptureStartTransaction.run {
                events.append("install")
            } start: {
                events.append("start")
                throw StartFailure()
            } rollback: {
                events.append("rollback")
            }
        )

        XCTAssertEqual(events, ["install", "start", "rollback"])
    }

    func testSuccessfulStartDoesNotRollback() throws {
        var events: [String] = []

        try CaptureStartTransaction.run {
            events.append("install")
        } start: {
            events.append("start")
        } rollback: {
            events.append("rollback")
        }

        XCTAssertEqual(events, ["install", "start"])
    }

    func testAbortClearsAnOpenedSTTUtteranceWithoutFinalInference() {
        let engine = STTEngine(
            nemotronRepo: "unused-test-repository",
            parakeetRepo: "unused-test-repository"
        )

        _ = engine.begin(language: nil, mode: .accurate)
        XCTAssertTrue(engine.hasActiveUtteranceForTesting)

        engine.abort()

        XCTAssertFalse(engine.hasActiveUtteranceForTesting)
        XCTAssertEqual(engine.latestCorrection().confirmed.renderedText, "")
        XCTAssertEqual(engine.latestCorrection().partial.renderedText, "")
    }
}
