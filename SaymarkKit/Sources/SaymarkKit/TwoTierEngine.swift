import Foundation
import MLX
import MLXAudioSTT

/// Saymark's two-tier composition policy. Caps Metal memory and loads the fast
/// (Nemotron) and/or accurate (Parakeet) models **lazily, per mode**: `prepare(.fast)`
/// never drags in Parakeet, `prepare(.accurate)` never loads Nemotron, and
/// switching modes loads only the missing model. It then vends a fresh session per
/// utterance (a session accumulates text, so each dictation needs a clean one).
///
/// This is **application** policy — which two models, how to merge them, the memory
/// budget — not a library primitive, so it lives in SaymarkKit, built on the
/// library's public streaming primitives (`fromPretrained` / `makeStreamSession`).
public final class TwoTierEngine {
    public static let defaultNemotronRepo = SaymarkModelCatalog.nemotron.repository
    public static let defaultParakeetRepo = SaymarkModelCatalog.parakeet.repository

    /// Fast-lane (Nemotron) chunk in ms — SSOT for both the hybrid fast lane and
    /// the fast-only mode. 160 ms (`[56,1]`, 1-chunk lookahead) beats 80 ms on
    /// BOTH RTF (−40 %) and WER (10.6 % vs 14.9 %) in the interleaved bench; the
    /// only cost is +80 ms partial latency, hidden while Parakeet refines at stop.
    public static let defaultFastChunkMs = 160

    private let nemotronRepo: String
    private let parakeetRepo: String
    private var nemotron: NemotronASRModel?
    private var parakeet: ParakeetModel?

    /// Caps Metal memory up front (an unbounded MLX run can OOM-reboot the Mac);
    /// models load lazily via `prepare`.
    public init(
        nemotronRepo: String = defaultNemotronRepo,
        parakeetRepo: String = defaultParakeetRepo,
        memoryLimitBytes: Int = 18 * 1024 * 1024 * 1024
    ) {
        Memory.memoryLimit = memoryLimitBytes
        self.nemotronRepo = nemotronRepo
        self.parakeetRepo = parakeetRepo
    }

    /// Download (first run) + load ONLY the models `mode` needs. Memoized — a model
    /// already loaded is reused, so a mode switch loads just what's missing.
    public func prepare(_ mode: DictationMode) async throws {
        SaymarkDiagnostics.log(.info, "models.prepare_started", fields: [
            "mode": mode.rawValue,
            "nemotron_loaded": nemotron != nil,
            "parakeet_loaded": parakeet != nil,
        ])
        switch mode {
        case .fast:     _ = try await loadNemotron()
        case .accurate: _ = try await loadParakeet()
        case .hybrid:   _ = try await loadNemotron(); _ = try await loadParakeet()
        }
    }

    /// Whether the models `mode` needs are loaded (so a session can be made).
    public func isReady(_ mode: DictationMode) -> Bool {
        switch mode {
        case .fast:     return nemotron != nil
        case .accurate: return parakeet != nil
        case .hybrid:   return nemotron != nil && parakeet != nil
        }
    }

    private func loadNemotron() async throws -> NemotronASRModel {
        if let nemotron {
            SaymarkDiagnostics.log(.debug, "model.reused", fields: ["lane": "nemotron", "repository": nemotronRepo])
            return nemotron
        }
        return try await loadModel(lane: "nemotron", repository: nemotronRepo) {
            let model = try await NemotronASRModel.fromPretrained(nemotronRepo)
            nemotron = model
            return model
        }
    }

    private func loadParakeet() async throws -> ParakeetModel {
        if let parakeet {
            SaymarkDiagnostics.log(.debug, "model.reused", fields: ["lane": "parakeet", "repository": parakeetRepo])
            return parakeet
        }
        return try await loadModel(lane: "parakeet", repository: parakeetRepo) {
            let model = try await ParakeetModel.fromPretrained(parakeetRepo)
            parakeet = model
            return model
        }
    }

    private func loadModel<Model>(
        lane: String,
        repository: String,
        operation: () async throws -> Model
    ) async throws -> Model {
        let started = ProcessInfo.processInfo.systemUptime
        SaymarkDiagnostics.log(.info, "model.load_started", fields: [
            "lane": lane,
            "repository": repository,
            "mlx_active_bytes": Memory.activeMemory,
            "mlx_cache_bytes": Memory.cacheMemory,
        ])
        do {
            let model = try await operation()
            SaymarkDiagnostics.log(.info, "model.load_completed", fields: [
                "lane": lane,
                "repository": repository,
                "duration_ms": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                "mlx_active_bytes": Memory.activeMemory,
                "mlx_cache_bytes": Memory.cacheMemory,
                "mlx_peak_bytes": Memory.peakMemory,
            ])
            return model
        } catch {
            SaymarkDiagnostics.log(.error, "model.load_failed", fields: [
                "lane": lane,
                "repository": repository,
                "duration_ms": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                "error_type": String(reflecting: type(of: error)),
                "error_description": error.localizedDescription,
            ])
            throw error
        }
    }

    /// The session for `mode`, or nil if its models aren't loaded yet (call
    /// `prepare(mode)` first). Single dispatch point — STTEngine uses it for both
    /// the warm-up pass and live dictation.
    func makeSession(for mode: DictationMode, language: String? = nil) -> UtteranceSession? {
        switch mode {
        case .hybrid:   return makeHybridSession(language: language)
        case .fast:     return makeFastSession(language: language)
        case .accurate: return makeAccurateSession()
        }
    }

    /// Hybrid: Nemotron supplies the live draft; Parakeet replaces it at stop.
    func makeHybridSession(
        language: String? = nil,
        fastChunkMs: Int = defaultFastChunkMs
    ) -> TwoTierSession? {
        guard let nemotron, let parakeet else { return nil }
        return TwoTierSession(
            nemotron: nemotron, parakeet: parakeet,
            language: language, fastChunkMs: fastChunkMs
        )
    }

    /// Fast lane only (Nemotron).
    func makeFastSession(language: String? = nil, chunkMs: Int = defaultFastChunkMs) -> UtteranceSession? {
        guard let nemotron else { return nil }
        return NemotronOnlySession(nemotron, language: language, chunkMs: chunkMs)
    }

    /// Accurate lane only: buffer the utterance, then run the very fast Parakeet pass.
    func makeAccurateSession() -> UtteranceSession? {
        guard let parakeet else { return nil }
        return ParakeetOnlySession(parakeet)
    }
}
