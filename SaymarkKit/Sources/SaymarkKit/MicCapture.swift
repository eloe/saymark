@preconcurrency import AVFoundation
import Foundation

/// Executes capture startup as a transaction: once installation succeeds, any
/// failure starting the underlying engine must run rollback before escaping.
struct CaptureStartTransaction {
    static func run(
        install: () -> Void,
        start: () throws -> Void,
        rollback: () -> Void
    ) throws {
        install()
        do {
            try start()
        } catch {
            rollback()
            throw error
        }
    }
}

public enum CaptureStopReason: Sendable, Equatable {
    case maximumDuration
    case backlogOverload
    case captureFailure
}

/// Pure accounting for audio admitted across the realtime/capture-queue boundary.
/// It bounds both retained utterance audio and closures waiting behind inference.
struct CaptureAdmissionBudget {
    struct Admission: Equatable {
        let acceptedCount: Int
        let newStopReason: CaptureStopReason?
    }

    let maximumTotalSamples: Int
    let maximumQueuedSamples: Int
    private(set) var totalAcceptedSamples = 0
    private(set) var queuedSamples = 0
    private(set) var stopReason: CaptureStopReason?

    mutating func reset() {
        totalAcceptedSamples = 0
        queuedSamples = 0
        stopReason = nil
    }

    mutating func reserve(_ requestedCount: Int) -> Admission {
        guard requestedCount > 0, stopReason == nil else { return Admission(acceptedCount: 0, newStopReason: nil) }
        let remaining = maximumTotalSamples - totalAcceptedSamples
        guard remaining > 0 else {
            stopReason = .maximumDuration
            return Admission(acceptedCount: 0, newStopReason: .maximumDuration)
        }
        let accepted = min(requestedCount, remaining)
        guard queuedSamples + accepted <= maximumQueuedSamples else {
            stopReason = .backlogOverload
            return Admission(acceptedCount: 0, newStopReason: .backlogOverload)
        }
        totalAcceptedSamples += accepted
        queuedSamples += accepted
        if totalAcceptedSamples == maximumTotalSamples {
            stopReason = .maximumDuration
            return Admission(acceptedCount: accepted, newStopReason: .maximumDuration)
        }
        return Admission(acceptedCount: accepted, newStopReason: nil)
    }

    mutating func complete(_ count: Int) {
        queuedSamples = max(0, queuedSamples - max(0, count))
    }

    mutating func terminate(_ reason: CaptureStopReason) -> Bool {
        guard stopReason == nil else { return false }
        stopReason = reason
        return true
    }
}

/// Captures the default input and resamples to 16 kHz mono Float, delivering
/// fixed 160 ms chunks via `onChunk`. Ported from the mic-compare CLI's MicRunner.
///
/// `@unchecked Sendable`: the input-tap closure runs on the realtime audio
/// thread, so it must NOT inherit actor isolation. All mutable state is confined
/// to `queue`; a single stateful `AVAudioConverter` keeps resampler continuity.
final class MicCapture: @unchecked Sendable {
    struct Result {
        let sampleCount: Int
        let durationS: Double
        let peakRMS: Float
        let inputSampleRate: Double
        let inputChannels: Int
        let inputBufferCount: Int
        let conversionErrorCount: Int
        let stopReason: CaptureStopReason?
    }

    /// Fixed-size 16 kHz mono chunks delivered on the capture queue.
    var onChunk: ([Float]) -> Void = { _ in }
    var onStopRequested: @Sendable (UInt64, CaptureStopReason) -> Void = { _, _ in }
    var onFirstAcceptedBuffer: @Sendable (TimeInterval) -> Void = { _ in }

    // This is the FEED size, not Nemotron's internal chunk. A 20-run
    // 160/240/320/480 ms experiment on the release model stack selected 160 ms:
    // it passed throughput, quality, step-latency, and memory gates without
    // backlog, while providing three times as many live-update opportunities as
    // the old 480 ms feed.
    static let feedSamples = 2_560
    static let feedIntervalMilliseconds = 160
    static let speechHangoverChunks = 6
    static let maximumUtteranceSamples = 10 * 60 * 16_000
    static let maximumBacklogSamples = 5 * 16_000
    private let chunkSize = feedSamples
    private let queue = DispatchQueue(label: "saymark.mic.capture")
    private let callbackGroup = DispatchGroup()
    private let engine = AVAudioEngine()
    private let lifecycleLock = NSLock()
    private var converter: AVAudioConverter?
    private var outFmt: AVAudioFormat?
    private var tapInstalled = false
    private var captureGeneration: UInt64 = 0
    private var acceptingCallbacks = false
    private var firstAcceptedBufferReported = false
    private var admission = CaptureAdmissionBudget(
        maximumTotalSamples: maximumUtteranceSamples,
        maximumQueuedSamples: maximumBacklogSamples
    )

    private var pending: [Float] = []
    private var totalSamples = 0
    private var peak: Float = 0
    private var inputSampleRate = 0.0
    private var inputChannels = 0
    private var inputBufferCount = 0
    private var conversionErrorCount = 0

    func start() throws {
        queue.sync {
            pending.removeAll(keepingCapacity: true)
            totalSamples = 0
            peak = 0
            inputBufferCount = 0
            conversionErrorCount = 0
        }

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: out)
        else {
            throw NSError(domain: "Saymark.MicCapture", code: 1, userInfo:
                [NSLocalizedDescriptionKey: "could not build a 16 kHz mono converter from \(inFmt)"])
        }
        let generation = lifecycleLock.withLock {
            captureGeneration &+= 1
            acceptingCallbacks = true
            firstAcceptedBufferReported = false
            outFmt = out
            converter = conv
            admission.reset()
            return captureGeneration
        }
        queue.sync {
            inputSampleRate = inFmt.sampleRate
            inputChannels = Int(inFmt.channelCount)
        }

        try CaptureStartTransaction.run {
            input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buffer, _ in
                guard let self else { return }
                callbackGroup.enter()
                defer { callbackGroup.leave() }
                ingest(buffer, generation: generation)
            }
            tapInstalled = true
            engine.prepare()
        } start: {
            try engine.start()
        } rollback: {
            abort()
        }
    }

    /// Stop capture, flush the trailing partial chunk, and report what was heard.
    func stop() -> Result {
        engine.stop()
        removeTapIfInstalled()
        // Tap removal prevents new callbacks. Wait for callbacks already inside
        // conversion to enqueue their work, then drain the serial capture queue
        // before invalidating this generation.
        callbackGroup.wait()
        let result = queue.sync {
            if !pending.isEmpty {
                onChunk(pending)
                pending.removeAll(keepingCapacity: true)
            }
            return Result(sampleCount: totalSamples,
                          durationS: Double(totalSamples) / 16000.0,
                          peakRMS: peak,
                          inputSampleRate: inputSampleRate,
                          inputChannels: inputChannels,
                          inputBufferCount: inputBufferCount,
                          conversionErrorCount: conversionErrorCount,
                          stopReason: lifecycleLock.withLock { admission.stopReason })
        }
        invalidateCallbacks()
        return result
    }

    /// Release partially or fully acquired capture resources without delivering
    /// buffered audio. Safe to call from startup rollback.
    func abort() {
        engine.stop()
        removeTapIfInstalled()
        invalidateCallbacks()
        queue.sync {
            pending.removeAll(keepingCapacity: false)
        }
    }

    private func removeTapIfInstalled() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func invalidateCallbacks() {
        lifecycleLock.withLock {
            acceptingCallbacks = false
            converter = nil
            outFmt = nil
        }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        let inputCallbackUptime = ProcessInfo.processInfo.systemUptime
        guard let (outFmt, converter) = lifecycleLock.withLock({ () -> (AVAudioFormat, AVAudioConverter)? in
            guard acceptingCallbacks, captureGeneration == generation,
                  admission.stopReason == nil,
                  let outFmt, let converter
            else { return nil }
            return (outFmt, converter)
        }) else { return }
        let ratio = outFmt.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else {
            requestTerminalStop(.captureFailure, generation: generation)
            return
        }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else {
            if requestTerminalStop(.captureFailure, generation: generation) {
                queue.async { [self] in conversionErrorCount += 1 }
            }
            return
        }

        let n = Int(out.frameLength)
        let converted = Array(UnsafeBufferPointer(start: ch[0], count: n))
        var sum: Float = 0
        for v in converted { sum += v * v }
        let rms = (sum / Float(max(1, n))).squareRoot()

        let admissionResult = lifecycleLock.withLock { admission.reserve(n) }
        let acceptedCount = admissionResult.acceptedCount
        if let reason = admissionResult.newStopReason {
            let callback = onStopRequested
            DispatchQueue.global(qos: .userInitiated).async { callback(generation, reason) }
        }
        guard acceptedCount > 0 else { return }
        let firstAcceptedCallback: (@Sendable (TimeInterval) -> Void)? = lifecycleLock.withLock {
            guard acceptingCallbacks, captureGeneration == generation,
                  !firstAcceptedBufferReported
            else { return nil }
            firstAcceptedBufferReported = true
            return onFirstAcceptedBuffer
        }
        if let firstAcceptedCallback {
            queue.async { firstAcceptedCallback(inputCallbackUptime) }
        }
        let chunk = acceptedCount == converted.count
            ? converted
            : Array(converted.prefix(acceptedCount))

        queue.async { [self] in
            defer { lifecycleLock.withLock { admission.complete(acceptedCount) } }
            guard lifecycleLock.withLock({
                acceptingCallbacks && captureGeneration == generation
            }) else { return }
            inputBufferCount += 1
            totalSamples += acceptedCount
            if rms > peak { peak = rms }
            pending.append(contentsOf: chunk)
            while pending.count >= chunkSize {
                let c = Array(pending.prefix(chunkSize))
                pending.removeFirst(chunkSize)
                onChunk(c)
            }
        }
    }

    @discardableResult
    private func requestTerminalStop(_ reason: CaptureStopReason, generation: UInt64) -> Bool {
        let callback: (@Sendable (UInt64, CaptureStopReason) -> Void)? = lifecycleLock.withLock {
            guard acceptingCallbacks, captureGeneration == generation,
                  admission.terminate(reason)
            else { return nil }
            return onStopRequested
        }
        guard let callback else { return false }
        DispatchQueue.global(qos: .userInitiated).async { callback(generation, reason) }
        return true
    }

    /// Mic TCC gate. Calls back on the main queue.
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }
}
