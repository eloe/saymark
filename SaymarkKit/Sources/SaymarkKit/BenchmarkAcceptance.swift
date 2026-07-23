import Foundation

public enum TranscriptionMetrics {
    /// Nearest-rank percentile. This deliberately reports an observed value rather
    /// than interpolating a duration that never occurred.
    public static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let bounded = min(1, max(0, percentile))
        let rank = max(1, Int(ceil(bounded * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }

    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let expected = words(reference)
        let actual = words(hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }

        var previous = Array(0 ... actual.count)
        for (expectedIndex, expectedWord) in expected.enumerated() {
            var current = [expectedIndex + 1]
            current.reserveCapacity(actual.count + 1)
            for (actualIndex, actualWord) in actual.enumerated() {
                let substitution = previous[actualIndex] + (expectedWord == actualWord ? 0 : 1)
                let deletion = previous[actualIndex + 1] + 1
                let insertion = current[actualIndex] + 1
                current.append(min(substitution, deletion, insertion))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

public struct BenchmarkBudget: Equatable, Sendable {
    public let maximumMedianRTF: Double
    public let maximumFinishSeconds: Double
    public let maximumP95StepSeconds: Double
    public let maximumStepSeconds: Double
    public let maximumWER: Double
    public let maximumPeakMemoryGB: Double
    public let maximumSettledMemoryGrowthGB: Double

    public init(
        maximumMedianRTF: Double,
        maximumFinishSeconds: Double,
        maximumP95StepSeconds: Double,
        maximumStepSeconds: Double,
        maximumWER: Double,
        maximumPeakMemoryGB: Double,
        maximumSettledMemoryGrowthGB: Double
    ) {
        self.maximumMedianRTF = maximumMedianRTF
        self.maximumFinishSeconds = maximumFinishSeconds
        self.maximumP95StepSeconds = maximumP95StepSeconds
        self.maximumStepSeconds = maximumStepSeconds
        self.maximumWER = maximumWER
        self.maximumPeakMemoryGB = maximumPeakMemoryGB
        self.maximumSettledMemoryGrowthGB = maximumSettledMemoryGrowthGB
    }

    /// Local acceptance gate for the current Apple Silicon development target.
    /// CI should run correctness tests; machine-specific performance runs are opt-in.
    public static let efficientAppleSilicon = Self(
        maximumMedianRTF: 0.08,
        maximumFinishSeconds: 2.0,
        maximumP95StepSeconds: 0.10,
        maximumStepSeconds: 0.25,
        maximumWER: 0.08,
        maximumPeakMemoryGB: 6.0,
        maximumSettledMemoryGrowthGB: 0.25
    )

    public static let livePreviewAppleSilicon = Self(
        maximumMedianRTF: 0.50,
        maximumFinishSeconds: 2.0,
        maximumP95StepSeconds: 0.25,
        maximumStepSeconds: 0.45,
        maximumWER: 0.08,
        maximumPeakMemoryGB: 6.0,
        maximumSettledMemoryGrowthGB: 0.25
    )
}

public struct BenchmarkMeasurement: Equatable, Sendable {
    public let medianRTF: Double
    public let finishSeconds: Double
    public let p95StepSeconds: Double
    public let maximumStepSeconds: Double
    public let wordErrorRate: Double
    public let peakMemoryGB: Double
    public let settledMemoryGrowthGB: Double

    public init(
        medianRTF: Double,
        finishSeconds: Double,
        p95StepSeconds: Double,
        maximumStepSeconds: Double,
        wordErrorRate: Double,
        peakMemoryGB: Double,
        settledMemoryGrowthGB: Double
    ) {
        self.medianRTF = medianRTF
        self.finishSeconds = finishSeconds
        self.p95StepSeconds = p95StepSeconds
        self.maximumStepSeconds = maximumStepSeconds
        self.wordErrorRate = wordErrorRate
        self.peakMemoryGB = peakMemoryGB
        self.settledMemoryGrowthGB = settledMemoryGrowthGB
    }
}

public enum BenchmarkViolation: Equatable, Sendable {
    case medianRTF(actual: Double, maximum: Double)
    case finishSeconds(actual: Double, maximum: Double)
    case p95StepSeconds(actual: Double, maximum: Double)
    case stepSeconds(actual: Double, maximum: Double)
    case wordErrorRate(actual: Double, maximum: Double)
    case peakMemoryGB(actual: Double, maximum: Double)
    case settledMemoryGrowthGB(actual: Double, maximum: Double)
}

public enum BenchmarkAcceptance {
    public static func violations(
        _ measurement: BenchmarkMeasurement,
        against budget: BenchmarkBudget
    ) -> [BenchmarkViolation] {
        var failures: [BenchmarkViolation] = []
        if measurement.medianRTF > budget.maximumMedianRTF {
            failures.append(.medianRTF(actual: measurement.medianRTF, maximum: budget.maximumMedianRTF))
        }
        if measurement.finishSeconds > budget.maximumFinishSeconds {
            failures.append(.finishSeconds(actual: measurement.finishSeconds, maximum: budget.maximumFinishSeconds))
        }
        if measurement.p95StepSeconds > budget.maximumP95StepSeconds {
            failures.append(.p95StepSeconds(
                actual: measurement.p95StepSeconds,
                maximum: budget.maximumP95StepSeconds
            ))
        }
        if measurement.maximumStepSeconds > budget.maximumStepSeconds {
            failures.append(.stepSeconds(actual: measurement.maximumStepSeconds, maximum: budget.maximumStepSeconds))
        }
        if measurement.wordErrorRate > budget.maximumWER {
            failures.append(.wordErrorRate(actual: measurement.wordErrorRate, maximum: budget.maximumWER))
        }
        if measurement.peakMemoryGB > budget.maximumPeakMemoryGB {
            failures.append(.peakMemoryGB(actual: measurement.peakMemoryGB, maximum: budget.maximumPeakMemoryGB))
        }
        if measurement.settledMemoryGrowthGB > budget.maximumSettledMemoryGrowthGB {
            failures.append(.settledMemoryGrowthGB(
                actual: measurement.settledMemoryGrowthGB,
                maximum: budget.maximumSettledMemoryGrowthGB
            ))
        }
        return failures
    }
}
