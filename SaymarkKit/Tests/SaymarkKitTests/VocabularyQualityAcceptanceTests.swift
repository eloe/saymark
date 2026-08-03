import Foundation
@testable import SaymarkKit
import XCTest

final class VocabularyQualityAcceptanceTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Rule: Decodable { let written: String; let heard: [String] }
        struct Case: Decodable {
            let split: String
            let category: String
            let raw: String
            let reference: String
            let expectedTarget: String?
            let targetOccurrences: Int
            let eligibleNegativeOccurrences: Int
        }
        let schemaVersion: Int
        let unicodeVersion: String
        let fixtureRevision: String
        let rulesFrozenBeforeEvaluation: Bool
        let rules: [Rule]
        let cases: [Case]
    }

    func testHeldOutSyntheticCorrectionQualityAndLatencyAcceptance() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.unicodeVersion, Unicode15_1.version)
        XCTAssertTrue(manifest.rulesFrozenBeforeEvaluation)
        XCTAssertFalse(manifest.cases.filter { $0.split == "development" }.isEmpty)

        let entries = manifest.rules.enumerated().map { index, rule in
            VocabularyEntry(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                written: rule.written,
                heard: rule.heard,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let snapshot = try VocabularySnapshot(document: VocabularyDocument(revision: 1, entries: entries))
        let evaluation = manifest.cases.filter { $0.split == "evaluation" }

        var rawTargetErrors = 0
        var correctedTargetErrors = 0
        var targetDenominator = 0
        var falseReplacements = 0
        var negativeDenominator = 0
        var rawWordErrors = 0
        var renderedWordErrors = 0
        var referenceWords = 0
        var latencies: [Double] = []

        for testCase in evaluation {
            let corrected = snapshot.correct(testCase.raw)
            XCTAssertEqual(snapshot.correct(testCase.raw), corrected, "nondeterministic case: \(testCase.category)")
            XCTAssertEqual(corrected.renderedText, testCase.reference, "fixture mismatch: \(testCase.category)")

            if let target = testCase.expectedTarget {
                let rawHits = occurrenceCount(of: target, in: testCase.raw)
                let correctedHits = occurrenceCount(of: target, in: corrected.renderedText)
                rawTargetErrors += abs(testCase.targetOccurrences - rawHits)
                correctedTargetErrors += abs(testCase.targetOccurrences - correctedHits)
                targetDenominator += testCase.targetOccurrences
            }
            if testCase.eligibleNegativeOccurrences > 0 {
                negativeDenominator += testCase.eligibleNegativeOccurrences
                if corrected.renderedText != testCase.raw {
                    falseReplacements += testCase.eligibleNegativeOccurrences
                }
            }

            let reference = normalizedWords(testCase.reference)
            rawWordErrors += editDistance(normalizedWords(testCase.raw), reference)
            renderedWordErrors += editDistance(normalizedWords(corrected.renderedText), reference)
            referenceWords += reference.count

            for _ in 0..<100 {
                let start = ContinuousClock.now
                _ = snapshot.correct(testCase.raw)
                latencies.append(milliseconds(start.duration(to: .now)))
            }
        }

        let rawTargetRate = Double(rawTargetErrors) / Double(targetDenominator)
        let correctedTargetRate = Double(correctedTargetErrors) / Double(targetDenominator)
        let relativeImprovement = (rawTargetRate - correctedTargetRate) / rawTargetRate
        let falseReplacementRate = Double(falseReplacements) / Double(negativeDenominator)
        let rawWER = Double(rawWordErrors) / Double(referenceWords)
        let renderedWER = Double(renderedWordErrors) / Double(referenceWords)
        let sortedLatency = latencies.sorted()
        let p95 = percentile(sortedLatency, 0.95)
        let maximum = sortedLatency.last ?? .infinity
        let targetInterval = wilson(successes: targetDenominator - correctedTargetErrors, total: targetDenominator)
        let negativeInterval = wilson(successes: falseReplacements, total: negativeDenominator)

        XCTAssertGreaterThanOrEqual(relativeImprovement, 0.50)
        XCTAssertLessThanOrEqual(renderedWER - rawWER, 0.005)
        XCTAssertLessThanOrEqual(falseReplacementRate, 0.01)
        XCTAssertLessThanOrEqual(p95, 10)
        XCTAssertLessThanOrEqual(maximum, 25)

        print(
            "VOCAB-QUALITY fixture=\(manifest.fixtureRevision) unicode=\(manifest.unicodeVersion) " +
            "evaluation_cases=\(evaluation.count) targets=\(targetDenominator) negatives=\(negativeDenominator) " +
            "raw_target_error=\(rawTargetRate) corrected_target_error=\(correctedTargetRate) " +
            "relative_improvement=\(relativeImprovement) corrected_target_success_ci95=\(targetInterval) " +
            "false_replacement=\(falseReplacementRate) false_replacement_ci95=\(negativeInterval) " +
            "raw_wer=\(rawWER) rendered_wer=\(renderedWER) latency_p95_ms=\(p95) latency_max_ms=\(maximum)"
        )
    }

    private func loadManifest() throws -> Manifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/vocabulary-quality-v1.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var remainder = haystack[...]
        while let range = remainder.range(of: needle) {
            count += 1
            remainder = remainder[range.upperBound...]
        }
        return count
    }

    private func normalizedWords(_ text: String) -> [String] {
        VocabularyNormalization.matchKey(text).split(separator: " ").map(String.init)
    }

    private func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var prior = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, right) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    prior[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    prior[rightIndex] + (left == right ? 0 : 1)
                )
            }
            prior = current
        }
        return prior[rhs.count]
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1)]
    }

    private func wilson(successes: Int, total: Int) -> String {
        guard total > 0 else { return "n/a" }
        let z = 1.959963984540054
        let n = Double(total)
        let p = Double(successes) / n
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let margin = z * sqrt((p * (1 - p) + z * z / (4 * n)) / n) / denominator
        return String(format: "%.6f...%.6f", max(0, center - margin), min(1, center + margin))
    }
}
