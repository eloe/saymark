import Foundation
import MLX
import MLXAudioSTT

// Two-stage ASR optimized for Apple laptops. Nemotron streams the live draft at
// low latency. We retain the gated speech samples and run one Parakeet pass when
// recording stops; on the target M2 that final pass takes a fraction of a second
// for a typical utterance, avoiding the growing backlog of a 4B streaming model.

public final class TwoTierSession {
    // Closures keep the live lane swappable between MLX and a future CoreML/ANE
    // implementation without coupling this composition policy to either type.
    private let fastStep: ([Float]) -> Void
    private let fastText: () -> String
    private let fastFinish: () -> Void
    private let accurateText: ([Float]) -> String
    private let releaseModelCache: () -> Void

    private var finalAudio = FinalAudioBuffer()
    private var finalText = ""

    init(
        fastStep: @escaping ([Float]) -> Void,
        fastText: @escaping () -> String,
        fastFinish: @escaping () -> Void,
        accurateText: @escaping ([Float]) -> String,
        releaseModelCache: @escaping () -> Void = { Memory.clearCache() }
    ) {
        self.fastStep = fastStep
        self.fastText = fastText
        self.fastFinish = fastFinish
        self.accurateText = accurateText
        self.releaseModelCache = releaseModelCache
    }

    public convenience init(
        fastStep: @escaping ([Float]) -> Void,
        fastText: @escaping () -> String,
        fastFinish: @escaping () -> Void,
        parakeet: ParakeetModel
    ) {
        self.init(
            fastStep: fastStep,
            fastText: fastText,
            fastFinish: fastFinish,
            accurateText: { parakeet.generate(audio: MLXArray($0)).text }
        )
    }

    /// Convenience: MLX Nemotron live lane.
    public convenience init(
        nemotron: NemotronASRModel,
        parakeet: ParakeetModel,
        language: String? = nil,
        fastChunkMs: Int = TwoTierEngine.defaultFastChunkMs
    ) {
        let fast = nemotron.makeStreamSession(language: language, chunkMs: fastChunkMs)
        self.init(
            fastStep: { _ = fast.step($0) },
            fastText: { fast.text },
            fastFinish: { _ = fast.finish() },
            parakeet: parakeet
        )
    }

    /// No text is confirmed until the final refinement pass completes.
    public var confirmed: String { finalText }

    /// Nemotron's current live draft.
    public var partial: String { finalText.isEmpty ? fastText() : "" }

    public var text: String { finalText.isEmpty ? fastText() : finalText }

    @discardableResult
    public func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        step(samples, processLiveDraft: true)
    }

    @discardableResult
    func step(
        _ samples: [Float],
        processLiveDraft: Bool
    ) -> (confirmed: String, partial: String) {
        finalAudio.append(samples, speechDetected: processLiveDraft)
        if processLiveDraft { fastStep(samples) }
        return (confirmed, partial)
    }

    /// Flush the live lane, then replace its draft with one accurate Parakeet pass.
    @discardableResult
    public func finish() -> (confirmed: String, partial: String) {
        fastFinish()
        let draft = fastText()
        if let audio = finalAudio.takeIfSpeechDetected() {
            let candidate = accurateText(audio)
            let candidateIsEmpty = candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            finalText = candidateIsEmpty ? draft : candidate
            let divergence = TranscriptDivergence(draft: draft, final: candidate)
            SaymarkDiagnostics.log(.info, "dictation.refinement_completed", fields: [
                "final_source": candidateIsEmpty ? "nemotron_fallback" : "parakeet",
                "draft_empty": divergence.draftWordCount == 0,
                "parakeet_empty": candidateIsEmpty,
            ])
        }
        releaseModelCache()
        return (finalText, "")
    }
}
