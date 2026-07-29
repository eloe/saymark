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

/// Keeps correction outside the ASR engines. It owns one immutable snapshot for
/// an utterance, so settings writes cannot change a visible draft or its final.
/// The wrapped session always receives and returns raw model text; correction is
/// applied once at the output boundary and never feeds back into ASR.
final class CorrectingUtteranceSession: UtteranceSession {
    private let base: UtteranceSession
    private let snapshot: VocabularySnapshot
    private let pipeline: TranscriptCorrectionPipeline
    private let onDraftCorrection: @Sendable (CorrectedTranscript, CorrectedTranscript) -> Void
    private let updateLock = NSLock()
    private var storedUpdate: (confirmed: CorrectedTranscript, partial: CorrectedTranscript)
    var latestUpdate: (confirmed: CorrectedTranscript, partial: CorrectedTranscript) { updateLock.withLock { storedUpdate } }

    init(
        base: UtteranceSession,
        snapshot: VocabularySnapshot,
        onDraftCorrection: @escaping @Sendable (CorrectedTranscript, CorrectedTranscript) -> Void = { _, _ in }
    ) {
        self.base = base; self.snapshot = snapshot; self.onDraftCorrection = onDraftCorrection
        pipeline = TranscriptCorrectionPipeline(snapshot: snapshot)
        let empty = CorrectedTranscript(rawText: "", renderedText: "", snapshotRevision: snapshot.revision, appliedRuleCount: 0)
        storedUpdate = (empty, empty)
    }

    func step(_ samples: [Float], shouldProcess: Bool) -> (confirmed: String, partial: String) {
        let raw = base.step(samples, shouldProcess: shouldProcess)
        // Correct the complete current hypothesis on the dedicated latest-wins
        // worker. No normalization/matching runs synchronously on the STT queue.
        let whole = raw.confirmed + raw.partial
        pipeline.submitDraft(whole) { [weak self] corrected in
            guard let self else { return }
            let empty = CorrectedTranscript(rawText: "", renderedText: "", snapshotRevision: corrected.snapshotRevision, appliedRuleCount: 0)
            self.updateLock.withLock { self.storedUpdate = (empty, corrected) }
            self.onDraftCorrection(empty, corrected)
        }
        return raw
    }

    var currentText: (confirmed: String, partial: String) {
        base.currentText
    }

    func finishText() -> String {
        // `base` returns its raw authoritative final. In the empty-Parakeet
        // fallback this is the raw Nemotron draft, therefore this is exactly one
        // correction pass and cannot cascade a previously rendered live draft.
        let final = pipeline.correctFinal(base.finishText())
        let empty = CorrectedTranscript(rawText: "", renderedText: "", snapshotRevision: snapshot.revision, appliedRuleCount: 0)
        updateLock.withLock { storedUpdate = (final, empty) }
        return final.renderedText
    }
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
