import Foundation

/// Retains the complete utterance for the authoritative final model while the
/// speech gate independently decides which chunks should run through a live
/// decoder. If no speech is ever detected, the buffer drains without inference.
struct FinalAudioBuffer {
    private var samples: [Float] = []
    private var speechDetected = false

    var sampleCount: Int { samples.count }

    mutating func append(_ newSamples: [Float], speechDetected: Bool) {
        samples.append(contentsOf: newSamples)
        self.speechDetected = self.speechDetected || speechDetected
    }

    mutating func takeIfSpeechDetected() -> [Float]? {
        defer {
            samples.removeAll(keepingCapacity: false)
            speechDetected = false
        }
        return speechDetected ? samples : nil
    }
}
