import Foundation

/// Retains the complete utterance for the authoritative final model while the
/// speech gate independently decides which chunks should run through a live
/// decoder. If no speech is ever detected, the buffer drains without inference.
struct FinalAudioBuffer {
    static let defaultMaximumSamples = MicCapture.maximumUtteranceSamples
    private var samples: [Float] = []
    private var speechDetected = false
    private var overflowed = false
    private let maximumSamples: Int

    init(maximumSamples: Int = Self.defaultMaximumSamples) {
        self.maximumSamples = max(0, maximumSamples)
    }

    var sampleCount: Int { samples.count }

    mutating func append(_ newSamples: [Float], speechDetected: Bool) {
        let remaining = max(0, maximumSamples - samples.count)
        if newSamples.count > remaining { overflowed = true }
        if remaining > 0 { samples.append(contentsOf: newSamples.prefix(remaining)) }
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
