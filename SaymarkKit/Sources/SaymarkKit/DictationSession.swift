import Foundation

public struct CaptureStopRequest: Sendable, Equatable {
    public let sessionID: String
    public let generation: UInt64
    public let reason: CaptureStopReason

    public func belongs(to activeSessionID: String?) -> Bool {
        sessionID == activeSessionID
    }
}

public struct DictationStopOutcome: Sendable, Equatable {
    public let text: String
    public let reason: CaptureStopReason?
    public var completedNormally: Bool {
        reason == nil || reason == .maximumDuration
    }
}

/// The UI-agnostic dictation pipeline shared by the menu-bar app and the CLI:
/// load the two-tier models (with warm-up), capture the mic in 160 ms chunks,
/// stream `(confirmed, partial)` updates, and flush a final transcript on stop.
///
/// No SwiftUI, no hotkey library, no text injection — callers wire those. The
/// only difference between the app and the CLI is who drives `start()`/`stop()`
/// and what they do with the transcript.
///
/// `@unchecked Sendable`: update subscribers fire on the mic capture queue and `stop()`
/// is meant to be called off the main thread; `start()`/`stop()` never overlap
/// (the caller's state machine guarantees it).
public final class DictationSession: @unchecked Sendable {
    private let engine: STTEngine
    private let correctionSnapshotProvider: @Sendable () -> VocabularySnapshot
    private var mic = MicCapture()
    private let updates = DictationUpdateHub()
    private let correctedUpdates = CorrectedDictationUpdateHub()
    private let captureStopRequests = CaptureStopRequestHub()
    private let activeSessionLock = NSLock()
    private var storedActiveSessionID: String?
    public var activeSessionID: String? {
        activeSessionLock.withLock { storedActiveSessionID }
    }

    private func setActiveSessionID(_ value: String?) {
        activeSessionLock.withLock { storedActiveSessionID = value }
    }

    public init(
        nemotronRepo: String = TwoTierEngine.defaultNemotronRepo,
        parakeetRepo: String = TwoTierEngine.defaultParakeetRepo,
        correctionSnapshotProvider: @escaping @Sendable () -> VocabularySnapshot = { .empty }
    ) {
        engine = STTEngine(nemotronRepo: nemotronRepo, parakeetRepo: parakeetRepo)
        self.correctionSnapshotProvider = correctionSnapshotProvider
    }

    /// Observe live `(confirmed, provisional)` updates. Retain the returned
    /// subscription for as long as updates are wanted. Handlers run on the mic
    /// capture queue; hop to the UI thread as needed.
    public func observeUpdates(
        _ handler: @escaping (_ confirmed: String, _ partial: String) -> Void
    ) -> DictationUpdateSubscription {
        updates.subscribe(handler)
    }

    /// Observe in-memory raw and rendered values for a current dictation. Do
    /// not retain these values outside the active UI/recovery flow.
    public func observeCorrectedUpdates(
        _ handler: @escaping (_ confirmed: CorrectedTranscript, _ partial: CorrectedTranscript) -> Void
    ) -> DictationUpdateSubscription { correctedUpdates.subscribe(handler) }

    public func observeCaptureStopRequests(
        _ handler: @escaping (CaptureStopRequest) -> Void
    ) -> DictationUpdateSubscription { captureStopRequests.subscribe(handler) }

    public var latestCorrectedTranscript: CorrectedTranscript {
        engine.latestCorrection().confirmed
    }

    /// Ready to record in `mode` — its models are loaded and warmed.
    public func isReady(_ mode: DictationMode = .hybrid) -> Bool { engine.isReady(mode) }

    /// Download (first run) + load + warm up ONLY the models `mode` needs. Heavy;
    /// await before `start(mode:)`. Defaults to hybrid (both lanes) for the CLI.
    public func load(mode: DictationMode = .hybrid) async throws {
        do {
            try await engine.prepare(mode)
        } catch {
            SaymarkDiagnostics.log(.error, "models.prepare_failed", fields: [
                "mode": mode.rawValue,
                "error_type": String(reflecting: type(of: error)),
            ])
            throw error
        }
    }

    /// Surface the microphone permission prompt early (no-op once granted).
    public func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void = { _ in }) {
        MicCapture.requestPermission { granted in
            SaymarkDiagnostics.log(granted ? .info : .warn, "microphone.permission", fields: [
                "granted": granted,
            ])
            completion(granted)
        }
    }

    /// Begin a fresh utterance and start capturing, with the chosen model mode.
    public func start(
        mode: DictationMode = .hybrid,
        onFirstCaptureBuffer: @escaping @Sendable (String, TimeInterval) -> Void = { _, _ in }
    ) throws {
        // Freeze the explicit local rules before audio capture begins. Later
        // edits/imports apply to the next utterance only.
        let correctionHub = correctedUpdates
        let sessionID = engine.begin(
            language: nil,
            mode: mode,
            correctionSnapshot: correctionSnapshotProvider(),
            onDraftCorrection: { confirmed, partial in
                correctionHub.publish(confirmed: confirmed, partial: partial)
            }
        )
        setActiveSessionID(sessionID)
        mic.onChunk = { [weak self] chunk in
            guard let self else { return }
            let (confirmed, partial) = self.engine.step(chunk)
            self.updates.publish(confirmed: confirmed, partial: partial)
        }
        mic.onStopRequested = { [weak self] generation, reason in
            self?.captureStopRequests.publish(.init(
                sessionID: sessionID,
                generation: generation,
                reason: reason
            ))
        }
        mic.onFirstAcceptedBuffer = { firstBufferUptime in
            onFirstCaptureBuffer(sessionID, firstBufferUptime)
        }
        do {
            try mic.start()
            SaymarkDiagnostics.log(.info, "microphone.capture_started", sessionID: sessionID, fields: [
                "feed_samples": MicCapture.feedSamples,
                "feed_interval_ms": MicCapture.feedIntervalMilliseconds,
                "target_sample_rate": 16_000,
            ])
        } catch {
            SaymarkDiagnostics.log(.error, "microphone.capture_failed", sessionID: sessionID, fields: [
                "error_type": String(reflecting: type(of: error)),
            ])
            mic.abort()
            mic.onChunk = { _ in }
            engine.abort()
            setActiveSessionID(nil)
            mic = MicCapture()
            throw error
        }
    }

    /// Stop capture, flush, and return the final transcript. Blocks while the
    /// backlog drains — call off the main thread.
    @discardableResult
    public func stop() -> DictationStopOutcome {
        let sessionID = activeSessionID
        let capture = mic.stop()
        SaymarkDiagnostics.log(.info, "microphone.capture_stopped", sessionID: sessionID, fields: [
            "sample_count": capture.sampleCount,
            "duration_seconds": capture.durationS,
            "peak_rms": capture.peakRMS,
            "input_sample_rate": capture.inputSampleRate,
            "input_channels": capture.inputChannels,
            "input_buffer_count": capture.inputBufferCount,
            "conversion_error_count": capture.conversionErrorCount,
            "capture_stop_reason": capture.stopReason.map { reason in
                switch reason {
                case .maximumDuration: "maximum_duration"
                case .backlogOverload: "backlog_overload"
                case .captureFailure: "capture_failure"
                }
            } ?? "user",
        ])
        let final: String
        if capture.stopReason == .backlogOverload || capture.stopReason == .captureFailure {
            engine.abort()
            final = ""
        } else {
            final = engine.finish()
        }
        let detailed = engine.latestCorrection()
        correctedUpdates.publish(confirmed: detailed.confirmed, partial: detailed.partial)
        mic = MicCapture()                               // fresh engine for the next gesture
        setActiveSessionID(nil)
        return DictationStopOutcome(text: final, reason: capture.stopReason)
    }

    /// Offline transcription of pre-loaded 16 kHz mono samples, feeding the same
    /// 160 ms chunks the mic path uses and timing the STT compute. For
    /// benchmarking against the CLI on a fixed file (no mic involved).
    public func transcribeOffline(
        _ samples: [Float],
        chunkSamples: Int = 2_560,
        mode: DictationMode = .hybrid
    ) -> OfflineResult {
        _ = engine.begin(language: nil, mode: mode, correctionSnapshot: correctionSnapshotProvider())
        let wall0 = ProcessInfo.processInfo.systemUptime
        var streamCompute = 0.0
        var maxStep = 0.0
        var stepSeconds: [Double] = []
        var i = 0
        while i < samples.count {
            let end = min(i + chunkSamples, samples.count)
            let chunk = Array(samples[i ..< end])
            let t0 = ProcessInfo.processInfo.systemUptime
            _ = engine.step(chunk)
            let elapsed = ProcessInfo.processInfo.systemUptime - t0
            streamCompute += elapsed
            maxStep = max(maxStep, elapsed)
            stepSeconds.append(elapsed)
            i = end
        }
        let tf = ProcessInfo.processInfo.systemUptime
        let text = engine.finish()
        let finishCompute = ProcessInfo.processInfo.systemUptime - tf
        let wall = ProcessInfo.processInfo.systemUptime - wall0
        return OfflineResult(
            text: text,
            audioSeconds: Double(samples.count) / 16000.0,
            streamComputeSeconds: streamCompute,
            finishComputeSeconds: finishCompute,
            wallSeconds: wall,
            maxStepSeconds: maxStep,
            stepSeconds: stepSeconds
        )
    }
}

public struct OfflineResult: Sendable {
    public let text: String
    public let audioSeconds: Double
    public let streamComputeSeconds: Double
    public let finishComputeSeconds: Double
    public let wallSeconds: Double      // total incl. chunk slicing overhead
    public let maxStepSeconds: Double
    public let stepSeconds: [Double]
    public var stepCount: Int { stepSeconds.count }
    public var computeSeconds: Double { streamComputeSeconds + finishComputeSeconds }
    public var rtf: Double { audioSeconds > 0 ? computeSeconds / audioSeconds : 0 }
}
