import XCTest
@testable import SaymarkKit

final class BenchmarkAcceptanceTests: XCTestCase {
    func test_percentileUsesNearestRankAndClampsBounds() {
        let values = [0.10, 0.20, 0.30, 0.40, 0.50]

        XCTAssertEqual(TranscriptionMetrics.percentile(values, percentile: 0.95), 0.50)
        XCTAssertEqual(TranscriptionMetrics.percentile(values, percentile: 0.50), 0.30)
        XCTAssertEqual(TranscriptionMetrics.percentile(values, percentile: 0), 0.10)
        XCTAssertEqual(TranscriptionMetrics.percentile(values, percentile: 2), 0.50)
        XCTAssertEqual(TranscriptionMetrics.percentile([], percentile: 0.95), 0)
    }

    func test_wordErrorRateNormalizesCaseAndPunctuation() {
        XCTAssertEqual(
            TranscriptionMetrics.wordErrorRate(
                reference: "Hello, WORLD! This is Saymark.",
                hypothesis: "hello world this is saymark"
            ),
            0,
            accuracy: 0.0001
        )
    }

    func test_wordErrorRateCountsSubstitutionsInsertionsAndDeletions() {
        XCTAssertEqual(
            TranscriptionMetrics.wordErrorRate(
                reference: "one two three four",
                hypothesis: "one too four extra"
            ),
            0.75,
            accuracy: 0.0001
        )
    }

    func test_acceptanceReportsEveryViolatedBudget() {
        let budget = BenchmarkBudget(
            maximumMedianRTF: 0.08,
            maximumFinishSeconds: 2.0,
            maximumP95StepSeconds: 0.20,
            maximumStepSeconds: 0.45,
            maximumWER: 0.08,
            maximumPeakMemoryGB: 6.0,
            maximumSettledMemoryGrowthGB: 0.25
        )
        let result = BenchmarkMeasurement(
            medianRTF: 0.10,
            finishSeconds: 2.1,
            p95StepSeconds: 0.30,
            maximumStepSeconds: 0.50,
            wordErrorRate: 0.09,
            peakMemoryGB: 6.1,
            settledMemoryGrowthGB: 0.30
        )

        XCTAssertEqual(BenchmarkAcceptance.violations(result, against: budget).count, 7)
    }

    func test_observedParakeetResultPassesEfficientBudget() {
        let result = BenchmarkMeasurement(
            medianRTF: 0.034,
            finishSeconds: 0.61,
            p95StepSeconds: 0.01,
            maximumStepSeconds: 0.01,
            wordErrorRate: 0,
            peakMemoryGB: 4.3,
            settledMemoryGrowthGB: 0.05
        )

        XCTAssertTrue(
            BenchmarkAcceptance.violations(
                result,
                against: .efficientAppleSilicon
            ).isEmpty
        )
    }

    func test_observedHybridResultPassesLivePreviewBudget() {
        let result = BenchmarkMeasurement(
            medianRTF: 0.306,
            finishSeconds: 0.65,
            p95StepSeconds: 0.18,
            maximumStepSeconds: 0.38,
            wordErrorRate: 0,
            peakMemoryGB: 4.3,
            settledMemoryGrowthGB: 0.05
        )

        XCTAssertTrue(
            BenchmarkAcceptance.violations(
                result,
                against: .livePreviewAppleSilicon
            ).isEmpty
        )
    }
}
