@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import SaymarkKit

/// Opt-in, real-model accuracy acceptance over the reproducible public corpus.
/// Ordinary `swift test` skips it and never downloads benchmark audio or models.
final class PublicCorpusAccuracyTests: XCTestCase {
    private struct SourceManifest: Decodable {
        struct Dataset: Decodable {
            let revision: String
            let license: String
        }

        struct Source: Decodable {
            let id: String
            let config: String
            let speakerID: Int
            let sha256: String
        }

        struct Case: Decodable {
            let id: String
            let scenario: String
            let targetDurationSeconds: Double?
            let sourceIds: [String]
            let repeatSourceIds: [String]?
        }

        let id: String
        let dataset: Dataset
        let sources: [Source]
        let cases: [Case]
    }

    private struct Corpus: Decodable {
        struct Dataset: Decodable {
            let revision: String
        }

        struct Acceptance: Decodable {
            let maximumMacroWordErrorRate: Double
            let maximumScenarioWordErrorRate: Double
            let maximumLocaleWordErrorRate: Double
        }

        struct Case: Decodable {
            let id: String
            let scenario: String
            let locale: String
            let audioPath: String
            let transcript: String
            let durationSeconds: Double
            let sha256: String
        }

        let corpusID: String
        let sourceManifestSHA256: String
        let dataset: Dataset
        let acceptance: Acceptance
        let cases: [Case]
    }

    private struct CaseResult: Codable {
        let id: String
        let scenario: String
        let locale: String
        let durationSeconds: Double
        let audioSHA256: String
        let reference: String
        let hypothesis: String
        let wordErrorRate: Double
    }

    private struct CorpusResult: Codable {
        let schemaVersion: Int
        let corpusID: String
        let profile: String
        let generatedAt: String
        let datasetRevision: String
        let sourceManifestSHA256: String
        let parakeetRepository: String
        let parakeetRevision: String?
        let nemotronRepository: String?
        let nemotronRevision: String?
        let macroWordErrorRate: Double
        let scenarioWordErrorRates: [String: Double]
        let localeWordErrorRates: [String: Double]
        let cases: [CaseResult]
        let violations: [String]
    }

    func testCheckedInPublicCorpusManifestHasRequiredFoundationCoverage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot
            .appendingPathComponent("Benchmarks/Corpus/saymark-english-v1.json")
        let manifest = try JSONDecoder().decode(
            SourceManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.id, "saymark-english-v1")
        XCTAssertEqual(
            manifest.dataset.revision,
            "71cacbfb7e2354c4226d01e70d77d5fca3d04ba1"
        )
        XCTAssertEqual(manifest.dataset.license, "CC-BY-4.0")
        XCTAssertEqual(manifest.sources.count, 10)
        XCTAssertEqual(Set(manifest.sources.map(\.id)).count, 10)
        XCTAssertEqual(Set(manifest.sources.map(\.speakerID)).count, 10)
        XCTAssertEqual(Set(manifest.sources.map(\.config)), ["clean", "other"])
        XCTAssertTrue(manifest.sources.allSatisfy {
            $0.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        })
        XCTAssertEqual(
            manifest.cases.filter { $0.scenario == "test-clean" }.count,
            5
        )
        XCTAssertEqual(
            manifest.cases.filter { $0.scenario == "test-other" }.count,
            5
        )
        XCTAssertEqual(
            manifest.cases.filter { $0.scenario == "pink-noise" }.count,
            2
        )
        XCTAssertEqual(
            manifest.cases.compactMap(\.targetDurationSeconds).sorted(),
            [30, 45, 60, 90, 120]
        )
        let long60 = try XCTUnwrap(manifest.cases.first { $0.id == "long-60s" })
        XCTAssertEqual(long60.sourceIds.count, 10)
        XCTAssertEqual(Set(long60.sourceIds).count, 10)
        for caseID in ["long-90s", "long-120s"] {
            let longCase = try XCTUnwrap(manifest.cases.first { $0.id == caseID })
            XCTAssertEqual(longCase.sourceIds.count, 10)
            XCTAssertEqual(Set(longCase.sourceIds).count, 10)
            XCTAssertEqual(longCase.repeatSourceIds?.count, 10)
            XCTAssertEqual(Set(longCase.repeatSourceIds ?? []).count, 10)
            XCTAssertNotEqual(longCase.sourceIds, longCase.repeatSourceIds)
        }
    }

    func testSelectedModelMeetsPublicCorpusAccuracyBudget() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["SAYMARK_CORPUS_MANIFEST"] else {
            throw XCTSkip("Run make test-corpus-efficient or make test-corpus-live")
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let corpus = try JSONDecoder().decode(
            Corpus.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 17)
        XCTAssertGreaterThanOrEqual(
            corpus.cases.filter { $0.scenario == "long-form" }.count,
            5
        )

        let profile = environment["SAYMARK_CORPUS_PROFILE"] ?? "efficient"
        let mode: DictationMode
        switch profile {
        case "efficient":
            mode = .accurate
        case "live-preview":
            mode = .hybrid
        default:
            XCTFail("Unknown SAYMARK_CORPUS_PROFILE: \(profile)")
            return
        }

        let parakeetRepository = environment["SAYMARK_PARAKEET_REPO"]
            ?? TwoTierEngine.defaultParakeetRepo
        let nemotronRepository = environment["SAYMARK_NEMOTRON_REPO"]
            ?? TwoTierEngine.defaultNemotronRepo
        let session = DictationSession(
            nemotronRepo: nemotronRepository,
            parakeetRepo: parakeetRepository
        )
        try await session.load(mode: mode)

        guard let warmup = corpus.cases.first else {
            XCTFail("Public corpus contains no cases")
            return
        }
        _ = session.transcribeOffline(
            try readAudio16kMono(manifestURL.deletingLastPathComponent()
                .appendingPathComponent(warmup.audioPath)),
            mode: mode
        )

        var caseResults: [CaseResult] = []
        for corpusCase in corpus.cases {
            let audioURL = manifestURL.deletingLastPathComponent()
                .appendingPathComponent(corpusCase.audioPath)
            let actualAudioSHA256 = try fileSHA256(audioURL)
            guard actualAudioSHA256 == corpusCase.sha256 else {
                XCTFail(
                    "\(corpusCase.id) audio SHA-256 mismatch: " +
                    "\(actualAudioSHA256) != \(corpusCase.sha256)"
                )
                return
            }
            let result = session.transcribeOffline(
                try readAudio16kMono(audioURL),
                mode: mode
            )
            caseResults.append(
                CaseResult(
                    id: corpusCase.id,
                    scenario: corpusCase.scenario,
                    locale: corpusCase.locale,
                    durationSeconds: corpusCase.durationSeconds,
                    audioSHA256: corpusCase.sha256,
                    reference: corpusCase.transcript,
                    hypothesis: result.text,
                    wordErrorRate: TranscriptionMetrics.wordErrorRate(
                        reference: corpusCase.transcript,
                        hypothesis: result.text
                    )
                )
            )
        }

        let macroWER = average(caseResults.map(\.wordErrorRate))
        let scenarioWERs = groupedAverages(caseResults, by: \.scenario)
        let localeWERs = groupedAverages(caseResults, by: \.locale)
        var violations: [String] = []
        if macroWER > corpus.acceptance.maximumMacroWordErrorRate {
            violations.append(
                "macro WER \(format(macroWER)) > \(format(corpus.acceptance.maximumMacroWordErrorRate))"
            )
        }
        for (scenario, wer) in scenarioWERs.sorted(by: { $0.key < $1.key })
        where wer > corpus.acceptance.maximumScenarioWordErrorRate {
            violations.append(
                "scenario \(scenario) WER \(format(wer)) > \(format(corpus.acceptance.maximumScenarioWordErrorRate))"
            )
        }
        for (locale, wer) in localeWERs.sorted(by: { $0.key < $1.key })
        where wer > corpus.acceptance.maximumLocaleWordErrorRate {
            violations.append(
                "locale \(locale) WER \(format(wer)) > \(format(corpus.acceptance.maximumLocaleWordErrorRate))"
            )
        }
        if let baselinePath = environment["SAYMARK_CORPUS_BASELINE"] {
            let baseline = try JSONDecoder().decode(
                CorpusResult.self,
                from: Data(contentsOf: URL(fileURLWithPath: baselinePath))
            )
            violations += regressionViolations(
                current: scenarioWERs,
                baseline: baseline.scenarioWordErrorRates,
                label: "scenario"
            )
            violations += regressionViolations(
                current: localeWERs,
                baseline: baseline.localeWordErrorRates,
                label: "locale"
            )
        }

        let report = CorpusResult(
            schemaVersion: 1,
            corpusID: corpus.corpusID,
            profile: profile,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            datasetRevision: corpus.dataset.revision,
            sourceManifestSHA256: corpus.sourceManifestSHA256,
            parakeetRepository: parakeetRepository,
            parakeetRevision: environment["SAYMARK_PARAKEET_REVISION"]
                ?? (parakeetRepository == SaymarkModelCatalog.parakeet.repository
                    ? SaymarkModelCatalog.parakeet.artifactSet.revision : nil),
            nemotronRepository: mode == .hybrid ? nemotronRepository : nil,
            nemotronRevision: mode == .hybrid
                ? environment["SAYMARK_NEMOTRON_REVISION"]
                    ?? (nemotronRepository == SaymarkModelCatalog.nemotron.repository
                        ? SaymarkModelCatalog.nemotron.artifactSet.revision : nil)
                : nil,
            macroWordErrorRate: macroWER,
            scenarioWordErrorRates: scenarioWERs,
            localeWordErrorRates: localeWERs,
            cases: caseResults,
            violations: violations
        )
        let reportData = try JSONEncoder.pretty.encode(report)
        if let outputPath = environment["SAYMARK_CORPUS_RESULTS"] {
            try reportData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }

        print(String(decoding: reportData, as: UTF8.self))
        XCTAssertTrue(violations.isEmpty, "Public corpus violations: \(violations)")
    }

    private func readAudio16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(file.length)
              )
        else {
            throw NSError(
                domain: "SaymarkPublicCorpus",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is not 16 kHz mono"]
            )
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func fileSHA256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func groupedAverages(
        _ results: [CaseResult],
        by keyPath: KeyPath<CaseResult, String>
    ) -> [String: Double] {
        Dictionary(grouping: results, by: { $0[keyPath: keyPath] })
            .mapValues { average($0.map(\.wordErrorRate)) }
    }

    private func regressionViolations(
        current: [String: Double],
        baseline: [String: Double],
        label: String
    ) -> [String] {
        current.compactMap { key, value in
            guard let prior = baseline[key], value - prior > 0.01 else { return nil }
            return "\(label) \(key) regressed \(format(value - prior)) absolute WER"
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
