import XCTest
@testable import SaymarkKit

final class TwoTierSessionTests: XCTestCase {
    func testDivergenceReportsCountsAndDistanceWithoutTranscriptContent() {
        let metrics = TranscriptDivergence(draft: "hello brave world", final: "hello world")

        XCTAssertEqual(metrics.draftWordCount, 3)
        XCTAssertEqual(metrics.finalWordCount, 2)
        XCTAssertEqual(metrics.wordEditDistance, 1)
        XCTAssertEqual(metrics.normalizedWordDistance, 1.0 / 3.0, accuracy: 0.001)
    }

    func testNonEmptyParakeetFinalReplacesNemotronDraft() {
        var draft = ""
        let session = TwoTierSession(
            fastStep: { _ in draft = "nemotron draft" },
            fastText: { draft },
            fastFinish: {},
            accurateText: { _ in "parakeet final" }
        )

        _ = session.step([0.1, 0.2], processLiveDraft: true)

        XCTAssertEqual(session.finish().confirmed, "parakeet final")
    }

    func testEmptyParakeetFinalFallsBackToNemotronDraft() {
        var draft = ""
        let session = TwoTierSession(
            fastStep: { _ in draft = "nemotron draft survives" },
            fastText: { draft },
            fastFinish: {},
            accurateText: { _ in "  \n " }
        )

        _ = session.step([0.1, 0.2], processLiveDraft: true)

        XCTAssertEqual(session.finish().confirmed, "nemotron draft survives")
    }
}
