import Foundation
import MLX
import MLXAudioSTT

/// Which model(s) transcribe an utterance.
public enum DictationMode: String, Sendable, CaseIterable {
    case fast       // Nemotron only — instant draft, lighter, lower accuracy
    case hybrid     // Nemotron live draft + Parakeet final refine (the default)
    case accurate   // Parakeet only — accurate final pass, no live draft
    case contextual // Qwen3-ASR only — LLM-grounded final pass that resolves
                    // homophones/names/punctuation from context, no live draft
}

/// The common surface STTEngine drives per utterance, regardless of mode.
protocol UtteranceSession {
    func step(_ samples: [Float], shouldProcess: Bool) -> (confirmed: String, partial: String)
    var currentText: (confirmed: String, partial: String) { get }
    func finishText() -> String
}

/// Two-tier (hybrid) lane: `step` already returns the confirmed/provisional split.
extension TwoTierSession: UtteranceSession {
    func step(_ samples: [Float], shouldProcess: Bool) -> (confirmed: String, partial: String) {
        step(samples, processLiveDraft: shouldProcess)
    }
    var currentText: (confirmed: String, partial: String) { (confirmed, partial) }
    func finishText() -> String { finish().confirmed }
}

/// Fast lane only (Nemotron). Its accumulated text is the confirmed output; there
/// is no provisional tail because there's no slower lane to refine against.
final class NemotronOnlySession: UtteranceSession {
    private let s: NemotronASRStreamSession
    init(_ model: NemotronASRModel, language: String?, chunkMs: Int) {
        s = model.makeStreamSession(language: language, chunkMs: chunkMs)
    }
    func step(_ samples: [Float], shouldProcess: Bool) -> (confirmed: String, partial: String) {
        if shouldProcess { _ = s.step(samples) }
        return (s.text, "")
    }
    var currentText: (confirmed: String, partial: String) { (s.text, "") }
    func finishText() -> String { _ = s.finish(); return s.text }
}

/// Accurate lane only: collect audio and run one Parakeet pass at stop. Parakeet's
/// warmed RTF is far below real time, so this avoids all growing streaming backlog.
final class ParakeetOnlySession: UtteranceSession {
    private let model: ParakeetModel
    private var finalAudio = FinalAudioBuffer()
    private var text = ""

    init(_ model: ParakeetModel) { self.model = model }
    func step(_ samples: [Float], shouldProcess: Bool) -> (confirmed: String, partial: String) {
        finalAudio.append(samples, speechDetected: shouldProcess)
        return (text, "")
    }
    var currentText: (confirmed: String, partial: String) { (text, "") }
    func finishText() -> String {
        guard let audio = finalAudio.takeIfSpeechDetected() else { return "" }
        text = model.generate(audio: MLXArray(audio)).text
        Memory.clearCache()
        return text
    }
}

/// Context-aware lane only: buffer the utterance, then run one Qwen3-ASR pass at
/// stop. Qwen3-ASR is an LLM-grounded ASR, so its final text resolves homophones,
/// names, and punctuation from sentence context — no streaming draft.
final class Qwen3OnlySession: UtteranceSession {
    private let model: Qwen3ASRModel
    private let context: String
    private var finalAudio = FinalAudioBuffer()
    private var text = ""

    /// `context` primes Qwen3's system prompt to bias recognition toward coined
    /// terms/names it wouldn't otherwise know (native ASR biasing — the correct
    /// alternative to post-hoc string replacement).
    init(_ model: Qwen3ASRModel, context: String = "") {
        self.model = model
        self.context = context
    }
    func step(_ samples: [Float], shouldProcess: Bool) -> (confirmed: String, partial: String) {
        finalAudio.append(samples, speechDetected: shouldProcess)
        return (text, "")
    }
    var currentText: (confirmed: String, partial: String) { (text, "") }
    func finishText() -> String {
        guard let audio = finalAudio.takeIfSpeechDetected() else { return "" }
        let p = model.defaultGenerationParameters
        // Biasing is only safe on longer clips. On very short audio the context
        // prompt leaks into / over-anchors the output, so skip it there.
        let audioSeconds = Double(audio.count) / 16_000.0
        let effectiveContext = audioSeconds >= 1.2 ? context : ""
        let raw = model.generate(
            audio: MLXArray(audio),
            maxTokens: p.maxTokens,
            temperature: p.temperature,
            context: effectiveContext,
            language: "en",            // force English — auto-detect hallucinates on short clips
            chunkDuration: p.chunkDuration,
            minChunkDuration: p.minChunkDuration
        ).text
        text = Qwen3OnlySession.stripLeak(raw, context: effectiveContext)
        Memory.clearCache()
        return text
    }

    /// Backstop: if the biasing context echoed into the transcript, strip it.
    static func stripLeak(_ text: String, context: String) -> String {
        guard !context.isEmpty else { return text }
        let cleaned = text
            .replacingOccurrences(of: context, with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }
}
