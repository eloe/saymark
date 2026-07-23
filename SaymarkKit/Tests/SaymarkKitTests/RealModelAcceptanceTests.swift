@preconcurrency import AVFoundation
import Foundation
import MLX
import XCTest
@testable import SaymarkKit

/// Opt-in hardware acceptance. Ordinary `swift test` skips this suite; local
/// model runs select one profile through environment variables so each profile
/// gets a fresh process and uncontaminated MLX peak-memory measurement.
final class RealModelAcceptanceTests: XCTestCase {
    func testSelectedModelProfileMeetsAcceptanceBudget() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let profileName = environment["SAYMARK_MODEL_PROFILE"] else {
            throw XCTSkip("Set SAYMARK_MODEL_PROFILE=efficient or live-preview")
        }
        guard let wavPath = environment["SAYMARK_MODEL_BENCHMARK_WAV"],
              let referencePath = environment["SAYMARK_MODEL_BENCHMARK_REFERENCE"]
        else {
            XCTFail("Model benchmarks require WAV and reference paths")
            return
        }

        let mode: DictationMode
        let budget: BenchmarkBudget
        switch profileName {
        case "efficient":
            mode = .accurate
            budget = .efficientAppleSilicon
        case "live-preview":
            mode = .hybrid
            budget = .livePreviewAppleSilicon
        default:
            XCTFail("Unknown SAYMARK_MODEL_PROFILE: \(profileName)")
            return
        }

        let samples = try readAudio16kMono(wavPath)
        let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
        let runs = Int(environment["SAYMARK_MODEL_BENCHMARK_RUNS"] ?? "") ?? 20
        let session = DictationSession(
            nemotronRepo: environment["SAYMARK_NEMOTRON_REPO"]
                ?? TwoTierEngine.defaultNemotronRepo,
            parakeetRepo: environment["SAYMARK_PARAKEET_REPO"]
                ?? TwoTierEngine.defaultParakeetRepo
        )
        try await session.load(mode: mode)
        let settledBaseline = Memory.activeMemory + Memory.cacheMemory

        var results: [OfflineResult] = []
        for _ in 0 ..< runs {
            results.append(session.transcribeOffline(samples, mode: mode))
        }

        // XCTest's process instrumentation can briefly suspend the measured
        // process. Keep it separate from the per-step latency acceptance above,
        // otherwise profiler pauses look like model backlog.
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(
            metrics: [XCTCPUMetric(), XCTMemoryMetric(), XCTClockMetric()],
            options: options
        ) {
            _ = session.transcribeOffline(samples, mode: mode)
        }

        Memory.clearCache()
        let settledMemory = Memory.activeMemory + Memory.cacheMemory
        let rtfs = results.map(\.rtf).sorted()
        let medianRTF = rtfs[rtfs.count / 2]
        let representative = results.min {
            abs($0.rtf - medianRTF) < abs($1.rtf - medianRTF)
        }!
        let measurement = BenchmarkMeasurement(
            medianRTF: medianRTF,
            finishSeconds: TranscriptionMetrics.percentile(
                results.map(\.finishComputeSeconds), percentile: 0.50
            ),
            p95StepSeconds: TranscriptionMetrics.percentile(
                results.flatMap(\.stepSeconds), percentile: 0.95
            ),
            maximumStepSeconds: results.map(\.maxStepSeconds).max() ?? 0,
            wordErrorRate: TranscriptionMetrics.wordErrorRate(
                reference: reference,
                hypothesis: representative.text
            ),
            peakMemoryGB: Double(Memory.peakMemory) / 1_000_000_000,
            settledMemoryGrowthGB: Double(max(0, settledMemory - settledBaseline)) / 1_000_000_000
        )
        let violations = BenchmarkAcceptance.violations(measurement, against: budget)

        print("MODEL_ACCEPTANCE profile=\(profileName) runs=\(runs) measurement=\(measurement)")
        XCTAssertTrue(violations.isEmpty, "Acceptance violations: \(violations)")
    }

    private func readAudio16kMono(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
        let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "SaymarkModelTests", code: 1)
        }
        try file.read(into: input)

        let capacity = AVAudioFrameCount(
            Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
        ) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw NSError(domain: "SaymarkModelTests", code: 2)
        }
        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            guard !suppliedInput else {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
