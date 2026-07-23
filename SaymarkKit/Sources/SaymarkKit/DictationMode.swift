import Foundation
import MLX
import MLXAudioSTT

/// Which model(s) transcribe an utterance.
public enum DictationMode: String, Sendable, CaseIterable {
    case fast       // Nemotron only — instant draft, lighter, lower accuracy
    case hybrid     // Nemotron live draft + Parakeet final refine (the default)
    case accurate   // Parakeet only — accurate final pass, no live draft
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
