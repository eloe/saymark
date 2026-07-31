import Foundation

/// Retains the complete utterance for the authoritative final model while the
/// speech gate independently decides which chunks should run through a live
/// decoder. If no speech is ever detected, the buffer drains without inference.
struct FinalAudioBuffer {
    private var samples: [Float] = []
    private var speechDetected = false
    private var overflowed = false
    private let maximumSamples: Int?

    /// Microphone capture is bounded before samples reach the STT engine. Offline
    /// files are already resident in memory and must not inherit that live-capture
    /// duration policy, so the default buffer is intentionally unbounded.
    init(maximumSamples: Int? = nil) {
        self.maximumSamples = maximumSamples.map { max(0, $0) }
    }

    var sampleCount: Int { samples.count }

    mutating func append(_ newSamples: [Float], speechDetected: Bool) {
        if let maximumSamples {
            let remaining = max(0, maximumSamples - samples.count)
            if newSamples.count > remaining { overflowed = true }
            if remaining > 0 { samples.append(contentsOf: newSamples.prefix(remaining)) }
        } else {
            samples.append(contentsOf: newSamples)
        }
        self.speechDetected = self.speechDetected || speechDetected
    }

    mutating func takeIfSpeechDetected() -> [Float]? {
        defer {
            samples.removeAll(keepingCapacity: false)
            speechDetected = false
            overflowed = false
        }
        return speechDetected && !overflowed ? samples : nil
    }
}
