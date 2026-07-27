import Foundation
import MLX
import MLXAudioVAD

/// Saymark's wrapper around `TwoTierEngine`, with a Silero VAD speech gate in front.
/// Loads models lazily per mode (Fast doesn't pull Parakeet), then opens a
/// fresh session + `SpeechGate` per utterance. Stepping is serialized on one queue
/// — MLX is not concurrency-safe, and the VAD shares that queue.
final class STTEngine: @unchecked Sendable {
    private struct SessionMetrics {
        let id: String
        let mode: DictationMode
        let startedUptime: TimeInterval
        var inputSamples = 0
        var inputChunks = 0
        var fedSamples = 0
        var fedChunks = 0
        var gatedChunks = 0
        var queueWaitSeconds: [Double] = []
        var vadSeconds: [Double] = []
        var asrSeconds: [Double] = []
    }

    private let queue = DispatchQueue(label: "saymark.stt")
    private let nemotronRepo: String
    private let parakeetRepo: String
    private var engine: TwoTierEngine?
    private var session: UtteranceSession?   // hybrid, Nemotron-only, or Parakeet-only per mode
    private var vad: SileroVAD?              // shared model; a fresh SpeechGate wraps it per utterance
    private var vadLoaded = false
    private var gate: SpeechGate?
    private var metrics: SessionMetrics?

    init(nemotronRepo: String, parakeetRepo: String) {
        self.nemotronRepo = nemotronRepo
        self.parakeetRepo = parakeetRepo
    }

    /// Ready to record in `mode` — its models are loaded and warmed.
    func isReady(_ mode: DictationMode) -> Bool {
        queue.sync { engine?.isReady(mode) ?? false }
    }

    /// Download (first run) + load + warm ONLY the models `mode` needs. Idempotent
    /// and memoized, so switching modes loads just the missing model. Loads the
    /// Silero gate once (best-effort: run ungated rather than fail the pipeline).
    func prepare(_ mode: DictationMode) async throws {
        let prepareStarted = ProcessInfo.processInfo.systemUptime
        let engine = queue.sync { () -> TwoTierEngine in
            if let existing = self.engine { return existing }
            let made = TwoTierEngine(                    // caps Metal memory in init
                nemotronRepo: nemotronRepo,
                parakeetRepo: parakeetRepo
            )
            self.engine = made
            return made
        }
        try await engine.prepare(mode)                   // async fromPretrained (memoized)

        if !queue.sync(execute: { vadLoaded }) {
            let vadStarted = ProcessInfo.processInfo.systemUptime
            let sileroDescriptor = SaymarkModelCatalog.silero
            SaymarkDiagnostics.log(.info, "vad.load_started", fields: [
                "repository": sileroDescriptor.repository,
                "revision": sileroDescriptor.revision,
            ])
            let silero: SileroVAD?
            do {
                _ = try await PinnedModelStore.shared.ensure(sileroDescriptor)
                silero = try await SileroVAD.fromPretrained(sileroDescriptor.repository)
            } catch {
                SaymarkDiagnostics.log(.warn, "vad.load_failed", fields: [
                    "repository": sileroDescriptor.repository,
                    "error_type": String(reflecting: type(of: error)),
                ])
                silero = nil
            }
            queue.sync {
                if let silero, let st = try? silero.initialState(sampleRate: 16000) {
                    _ = try? silero.feed(chunk: MLXArray([Float](repeating: 0, count: 512)), state: st)
                }
                vad = silero
                vadLoaded = true
            }
            SaymarkDiagnostics.log(silero == nil ? .warn : .info, "vad.load_completed", fields: [
                "repository": "mlx-community/silero-vad",
                "duration_ms": (ProcessInfo.processInfo.systemUptime - vadStarted) * 1_000,
                "available": silero != nil,
            ])
        }

        // Warm the mode's models on our queue — the first inference JIT-compiles
        // every Metal kernel (tens of seconds of stalls); do it here, off the first
        // dictation. Re-warming an already-JIT'd model is cheap.
        let warmStarted = ProcessInfo.processInfo.systemUptime
        queue.sync {
            if let warm = engine.makeSession(for: mode, language: nil) {
                _ = warm.step([Float](repeating: 0, count: 16000), shouldProcess: true)
                _ = warm.finishText()
            }
        }
        SaymarkDiagnostics.log(.info, "models.prepare_completed", fields: [
            "mode": mode.rawValue,
            "duration_ms": (ProcessInfo.processInfo.systemUptime - prepareStarted) * 1_000,
            "warmup_ms": (ProcessInfo.processInfo.systemUptime - warmStarted) * 1_000,
            "vad_available": queue.sync { vad != nil },
            "mlx_active_bytes": Memory.activeMemory,
            "mlx_cache_bytes": Memory.cacheMemory,
            "mlx_peak_bytes": Memory.peakMemory,
        ])
    }

    /// Open a clean session + gate for a new utterance, per the chosen model mode.
    func begin(language: String?, mode: DictationMode, correctionSnapshot: VocabularySnapshot = .empty) -> String {
        let id = UUID().uuidString.lowercased()
        queue.sync {
            session = engine?.makeSession(for: mode, language: language).map {
                CorrectingUtteranceSession(base: $0, snapshot: correctionSnapshot)
            }
            gate = vad.flatMap { try? SpeechGate(vad: $0) }
            metrics = SessionMetrics(
                id: id,
                mode: mode,
                startedUptime: ProcessInfo.processInfo.systemUptime
            )
        }
        SaymarkDiagnostics.log(.info, "dictation.pipeline_started", sessionID: id, fields: [
            "mode": mode.rawValue,
            "language": language ?? "auto",
            "vad_enabled": queue.sync { gate != nil },
        ])
        return id
    }

    /// Feed one 16 kHz mono chunk — but only if the gate says it's speech. On a
    /// gated (silent) chunk, return the current text without advancing the STT,
    /// so silence neither costs compute nor produces hallucinated finals.
    @discardableResult
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        let requested = ProcessInfo.processInfo.systemUptime
        return queue.sync {
            guard let session else { return ("", "") }
            let entered = ProcessInfo.processInfo.systemUptime
            let queueWait = entered - requested
            let vadStarted = ProcessInfo.processInfo.systemUptime
            let shouldFeed = gate?.shouldFeed(samples) ?? true
            let vadElapsed = ProcessInfo.processInfo.systemUptime - vadStarted
            metrics?.inputSamples += samples.count
            metrics?.inputChunks += 1
            metrics?.queueWaitSeconds.append(queueWait)
            metrics?.vadSeconds.append(vadElapsed)

            let asrStarted = ProcessInfo.processInfo.systemUptime
            let result = session.step(samples, shouldProcess: shouldFeed)
            let asrElapsed = ProcessInfo.processInfo.systemUptime - asrStarted
            if shouldFeed {
                metrics?.fedSamples += samples.count
                metrics?.fedChunks += 1
            } else {
                metrics?.gatedChunks += 1
            }
            metrics?.asrSeconds.append(asrElapsed)

            if let metrics {
                SaymarkDiagnostics.log(.trace, "dictation.step", sessionID: metrics.id, fields: [
                    "step_index": metrics.inputChunks,
                    "samples": samples.count,
                    "fed": shouldFeed,
                    "queue_wait_ms": queueWait * 1_000,
                    "vad_ms": vadElapsed * 1_000,
                    "asr_ms": asrElapsed * 1_000,
                    "confirmed_characters": result.confirmed.count,
                    "partial_characters": result.partial.count,
                    "mlx_active_bytes": Memory.activeMemory,
                    "mlx_cache_bytes": Memory.cacheMemory,
                ])
            }
            return result
        }
    }

    /// Flush and end the utterance; returns the mode's final transcript.
    func finish() -> String {
        queue.sync {
            let finishStarted = ProcessInfo.processInfo.systemUptime
            let text = session?.finishText() ?? ""
            let finishSeconds = ProcessInfo.processInfo.systemUptime - finishStarted
            if let metrics {
                let audioSeconds = Double(metrics.inputSamples) / 16_000.0
                let asrCompute = metrics.asrSeconds.reduce(0, +)
                let computeSeconds = asrCompute + finishSeconds
                SaymarkDiagnostics.log(.info, "dictation.pipeline_completed", sessionID: metrics.id, fields: [
                    "mode": metrics.mode.rawValue,
                    "recording_wall_ms": (ProcessInfo.processInfo.systemUptime - metrics.startedUptime) * 1_000,
                    "audio_seconds": audioSeconds,
                    "input_chunks": metrics.inputChunks,
                    "fed_chunks": metrics.fedChunks,
                    "gated_chunks": metrics.gatedChunks,
                    "fed_audio_seconds": Double(metrics.fedSamples) / 16_000.0,
                    "queue_wait_p95_ms": Self.percentile(metrics.queueWaitSeconds, 0.95) * 1_000,
                    "queue_wait_max_ms": (metrics.queueWaitSeconds.max() ?? 0) * 1_000,
                    "vad_p95_ms": Self.percentile(metrics.vadSeconds, 0.95) * 1_000,
                    "asr_step_p50_ms": Self.percentile(metrics.asrSeconds, 0.50) * 1_000,
                    "asr_step_p95_ms": Self.percentile(metrics.asrSeconds, 0.95) * 1_000,
                    "asr_step_max_ms": (metrics.asrSeconds.max() ?? 0) * 1_000,
                    "asr_stream_compute_ms": asrCompute * 1_000,
                    "finish_compute_ms": finishSeconds * 1_000,
                    "compute_rtf": audioSeconds > 0 ? computeSeconds / audioSeconds : 0,
                    "result_characters": text.count,
                    "result_words": text.split(separator: " ").count,
                    "result_empty": text.isEmpty,
                    "mlx_active_bytes": Memory.activeMemory,
                    "mlx_cache_bytes": Memory.cacheMemory,
                    "mlx_peak_bytes": Memory.peakMemory,
                ])
            }
            session = nil
            gate = nil
            metrics = nil
            return text
        }
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(0, index), sorted.count - 1)]
    }
}
