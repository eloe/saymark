@preconcurrency import AVFoundation
import Foundation
import MLX
import MLXAudioSTT
import SaymarkKit

// saymark-cli — the same dictation core (SaymarkKit) as the menu-bar app.
//   saymark-cli                  → live mic: speak, press Enter, print transcript
//   saymark-cli --wav <file> --mode fast|hybrid|accurate [--runs N]

let args = CommandLine.arguments
let session = DictationSession()

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let modeName = option("--mode") ?? DictationMode.hybrid.rawValue
guard let mode = DictationMode(rawValue: modeName) else {
    FileHandle.standardError.write(Data("invalid --mode '\(modeName)'; use fast, hybrid, or accurate\n".utf8))
    exit(2)
}
let runsText = option("--runs") ?? "1"
guard let runs = Int(runsText), runs > 0 else {
    FileHandle.standardError.write(Data("invalid --runs '\(runsText)'; use a positive integer\n".utf8))
    exit(2)
}

/// Read any audio file and resample to 16 kHz mono Float.
func readWav16kMono(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFmt = file.processingFormat
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                     channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: inFmt, to: outFmt),
          let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "saymark-cli", code: 1) }
    try file.read(into: inBuf)

    let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000.0 / inFmt.sampleRate) + 1024
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return [] }
    var done = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
        if done { status.pointee = .noDataNow; return nil }
        done = true; status.pointee = .haveData; return inBuf
    }
    guard err == nil, let ch = outBuf.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
}

if let wavIdx = args.firstIndex(of: "--wav"), wavIdx + 1 < args.count {
    // ---- Offline benchmark on a fixed file ----
    let path = args[wavIdx + 1]
    let samples = try readWav16kMono(path)

    if option("--candidate") == "parakeet" {
        let repo = "mlx-community/parakeet-tdt-0.6b-v3"
        let useANE = args.contains("--ane")
        FileHandle.standardError.write(Data("loading Parakeet candidate (ANE: \(useANE ? "on" : "off"))…\n".utf8))
        let candidate = try await ParakeetModel.fromPretrained(
            repo,
            aneEncoder: useANE ? .on : .off
        )
        let audio = MLXArray(samples)
        var times: [Double] = []
        var transcript = ""
        for run in 1 ... runs {
            let t0 = ProcessInfo.processInfo.systemUptime
            let output = candidate.generate(
                audio: audio,
                generationParameters: candidate.defaultGenerationParameters
            )
            let elapsed = ProcessInfo.processInfo.systemUptime - t0
            times.append(elapsed)
            transcript = output.text
            print(String(format: "run %-2d  wall %6.2fs  RTF %.3f", run, elapsed,
                         elapsed / (Double(samples.count) / 16000.0)))
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: """

            === candidate benchmark: Parakeet TDT 0.6B v3 / ANE %@ ===
            audio        %.2f s
            median RTF   %.3f
            """, useANE ? "on" : "off", Double(samples.count) / 16000.0,
            median / (Double(samples.count) / 16000.0)))
        print("\ntext: \(transcript)")
        exit(0)
    }

    if option("--candidate") == "qwen3" {
        let repo = "mlx-community/Qwen3-ASR-0.6B-4bit"
        FileHandle.standardError.write(Data("loading Qwen3-ASR 0.6B 4-bit candidate…\n".utf8))
        let candidate = try await Qwen3ASRModel.fromPretrained(repo)
        let audio = MLXArray(samples)
        var times: [Double] = []
        var transcript = ""
        for run in 1 ... runs {
            let t0 = ProcessInfo.processInfo.systemUptime
            let output = candidate.generate(audio: audio)
            let elapsed = ProcessInfo.processInfo.systemUptime - t0
            times.append(elapsed)
            transcript = output.text
            print(String(format: "run %-2d  wall %6.2fs  RTF %.3f", run, elapsed,
                         elapsed / (Double(samples.count) / 16000.0)))
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: """

            === candidate benchmark: Qwen3-ASR 0.6B / 4-bit ===
            audio        %.2f s
            median RTF   %.3f
            """, Double(samples.count) / 16000.0,
            median / (Double(samples.count) / 16000.0)))
        print("\ntext: \(transcript)")
        exit(0)
    }

    FileHandle.standardError.write(Data("loading \(mode.rawValue) model(s) (warming up MLX)…\n".utf8))
    try await session.load(mode: mode)
    // Force lazy MLX kernels and execution paths to compile before the measured
    // runs. The acceptance policy explicitly excludes first-compilation cost.
    _ = session.transcribeOffline(samples, mode: mode)
    Memory.clearCache()
    let settledMemoryBaseline = Memory.activeMemory + Memory.cacheMemory
    FileHandle.standardError.write(Data(
        String(format: "transcribing %.1fs of audio in %@ mode, %d run(s) (480 ms chunks)…\n",
               Double(samples.count) / 16000.0, mode.rawValue, runs).utf8))

    var results: [OfflineResult] = []
    for run in 1 ... runs {
        let result = session.transcribeOffline(samples, mode: mode)
        results.append(result)
        let quarter = max(1, result.stepSeconds.count / 4)
        let early = result.stepSeconds.prefix(quarter).reduce(0, +) / Double(quarter)
        let late = result.stepSeconds.suffix(quarter).reduce(0, +) / Double(quarter)
        print(String(format: "run %-2d  stream %6.2fs  finish %5.2fs  step early/late %.2f/%.2fs  max %.2fs  RTF %.3f",
                     run, result.streamComputeSeconds, result.finishComputeSeconds,
                     early, late, result.maxStepSeconds, result.rtf))
    }

    let sortedRTF = results.map(\.rtf).sorted()
    let medianRTF = sortedRTF[sortedRTF.count / 2]
    let medianFinish = results.map(\.finishComputeSeconds).sorted()[results.count / 2]
    let representative = results.min { abs($0.rtf - medianRTF) < abs($1.rtf - medianRTF) }!
    print(String(format: """

        === saymark-cli benchmark: %@ / %@ ===
        audio        %.2f s (%d chunks)
        median RTF   %.3f     (<1 = faster than realtime)
        """, (path as NSString).lastPathComponent, mode.rawValue,
        representative.audioSeconds, representative.stepCount, medianRTF))
    print("\ntext: \(representative.text)")

    if let acceptanceName = option("--accept") {
        guard let referencePath = option("--reference") else {
            FileHandle.standardError.write(Data("--accept requires --reference <text-file>\n".utf8))
            exit(2)
        }
        let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
        let budget: BenchmarkBudget
        switch acceptanceName {
        case "efficient":
            guard mode == .accurate else {
                FileHandle.standardError.write(Data("efficient acceptance requires --mode accurate\n".utf8))
                exit(2)
            }
            budget = .efficientAppleSilicon
        case "live-preview":
            guard mode == .hybrid else {
                FileHandle.standardError.write(Data("live-preview acceptance requires --mode hybrid\n".utf8))
                exit(2)
            }
            budget = .livePreviewAppleSilicon
        default:
            FileHandle.standardError.write(Data("unknown acceptance profile '\(acceptanceName)'\n".utf8))
            exit(2)
        }

        Memory.clearCache()
        let settledMemory = Memory.activeMemory + Memory.cacheMemory
        let measurement = BenchmarkMeasurement(
            medianRTF: medianRTF,
            finishSeconds: medianFinish,
            p95StepSeconds: TranscriptionMetrics.percentile(
                results.flatMap(\.stepSeconds),
                percentile: 0.95
            ),
            maximumStepSeconds: results.map(\.maxStepSeconds).max() ?? 0,
            wordErrorRate: TranscriptionMetrics.wordErrorRate(
                reference: reference,
                hypothesis: representative.text
            ),
            peakMemoryGB: Double(Memory.peakMemory) / 1_000_000_000,
            settledMemoryGrowthGB: Double(max(0, settledMemory - settledMemoryBaseline)) / 1_000_000_000
        )
        let violations = BenchmarkAcceptance.violations(measurement, against: budget)
        print(String(format: "acceptance   %@  WER %.3f  step p95/max %.3f/%.3fs  peak %.2f GB  settled growth %.2f GB",
                     violations.isEmpty ? "PASS" : "FAIL", measurement.wordErrorRate,
                     measurement.p95StepSeconds, measurement.maximumStepSeconds,
                     measurement.peakMemoryGB, measurement.settledMemoryGrowthGB))
        if !violations.isEmpty {
            for violation in violations { print("  - \(violation)") }
            exit(3)
        }
    }
} else {
    // ---- Live mic ----
    // Live two-tier view: Nemotron supplies the draft while Parakeet refines at stop.
    // Showing the
    // last ~100 chars keeps it to one terminal line (no flood).
    let updateSubscription = session.observeUpdates { confirmed, partial in
        let line = partial.isEmpty ? confirmed : "\(confirmed) ⟨\(partial)⟩"
        let tail = line.count > 100 ? "…" + String(line.suffix(100)) : line
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(tail)".utf8))
    }

    FileHandle.standardError.write(Data("loading \(mode.rawValue) model(s) (warming up MLX)…\n".utf8))
    try await session.load(mode: mode)
    try session.start(mode: mode)
    FileHandle.standardError.write(Data("\nREADY: speak now — press Enter to stop.\n".utf8))
    _ = readLine()
    let final = session.stop()
    withExtendedLifetime(updateSubscription) {}
    print("\n\nFINAL: \(final)")
}
