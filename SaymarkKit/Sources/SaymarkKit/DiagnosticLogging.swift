import Foundation
import OSLog

/// Increasing verbosity. A configured level includes every level below it.
public enum SaymarkLogLevel: Int, CaseIterable, Codable, Sendable {
    case off = 0
    case error
    case warn
    case info
    case debug
    case trace

    public init?(configurationValue: String) {
        switch configurationValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "none": self = .off
        case "error": self = .error
        case "warn", "warning": self = .warn
        case "info": self = .info
        case "debug", "verbose": self = .debug
        case "trace": self = .trace
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .off: "off"
        case .error: "error"
        case .warn: "warn"
        case .info: "info"
        case .debug: "debug"
        case .trace: "trace"
        }
    }
}

public struct SaymarkDiagnosticsConfiguration: Sendable {
    public var level: SaymarkLogLevel
    public var fileURL: URL
    public var maxFileBytes: Int
    public var retainedFiles: Int

    public init(
        level: SaymarkLogLevel,
        fileURL: URL,
        maxFileBytes: Int = 20 * 1024 * 1024,
        retainedFiles: Int = 3
    ) {
        self.level = level
        self.fileURL = fileURL
        self.maxFileBytes = max(1_048_576, maxFileBytes)
        self.retainedFiles = max(1, retainedFiles)
    }
}

/// Privacy-safe, machine-readable diagnostics used by both the app and SaymarkKit.
/// Callers must never put audio, transcript text, clipboard data, or selected text
/// in `fields`. Transcript-derived exact counts are excluded because they can
/// become content fingerprints; timing and resource measurements are safe.
public enum SaymarkDiagnostics {
    private static let storage = DiagnosticStorage()

    public static var level: SaymarkLogLevel { storage.level }
    public static var fileURL: URL? { storage.fileURL }

    public static func configure(_ configuration: SaymarkDiagnosticsConfiguration) {
        storage.configure(configuration)
    }

    public static func isEnabled(_ level: SaymarkLogLevel) -> Bool {
        storage.isEnabled(level)
    }

    public static func log(
        _ level: SaymarkLogLevel,
        _ event: String,
        sessionID: String? = nil,
        fields: [String: Any] = [:]
    ) {
        storage.log(level, event: event, sessionID: sessionID, fields: fields)
    }

    /// The sole diagnostic route for Recent Dictations.  It accepts only closed
    /// enums and deliberately has no text, record-id, path, search, destination
    /// or raw-error parameter.
    public static func logHistoryOperation(
        _ operation: HistoryDiagnosticOperation,
        outcome: HistoryDiagnosticOutcome,
        retention: HistoryRetentionPolicy? = nil,
        resultCount: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        var fields: [String: Any] = [
            "history_operation": operation.rawValue,
            "history_outcome": outcome.rawValue,
        ]
        if let retention { fields["history_retention"] = retention.rawValue }
        if let resultCount { fields["history_result_count"] = min(max(resultCount, 0), 25) }
        if let durationMilliseconds { fields["history_duration_ms"] = min(max(durationMilliseconds, 0), 60_000) }
        storage.log(.info, event: "history.operation", sessionID: nil, fields: fields)
    }
}

public enum HistoryDiagnosticOperation: String, Sendable {
    case insert, query, delete, clear, purge
    case policyChange = "policy_change"
}

public enum HistoryDiagnosticOutcome: String, Sendable {
    case success, unavailable, corrupt
    case migrationFailed = "migration_failed"
    case permissionDenied = "permission_denied"
    case busy
    case ioFailed = "io_failed"
    case unsupportedFilesystem = "unsupported_filesystem"
    case deadlineExceeded = "deadline_exceeded"
    case cleanupIncomplete = "cleanup_incomplete"
    case recordTooLarge = "record_too_large"
    case recordLimitReached = "record_limit_reached"
}

private final class DiagnosticStorage: @unchecked Sendable {
    /// The complete privacy boundary for caller-supplied diagnostic fields.
    /// Unknown names are discarded, even when their values happen to be JSON
    /// scalars, so a typo or newly invented field cannot leak application data.
    private static let allowedFieldNames: Set<String> = [
        "accessibility_granted", "accessibility_trusted", "asr_ms",
        "asr_step_max_ms", "asr_step_p50_ms", "asr_step_p95_ms",
        "asr_stream_compute_ms", "audio_seconds", "available", "behavior",
        "build", "bundle_id", "compute_rtf",
        "configured_level", "conversion_error_count",
        "count", "cpu_percent", "destination", "draft_empty",
        "duration_ms", "duration_seconds", "error_type", "fallback", "fed",
        "fed_audio_seconds", "fed_chunks", "feed_interval_ms", "feed_samples",
        "final_source", "finish_compute_ms", "from_mode",
        "gated_chunks", "granted", "history_duration_ms", "history_operation",
        "history_outcome", "history_result_count", "history_retention",
        "input_buffer_count", "input_channels",
        "input_chunks", "input_sample_rate", "insert_mode", "interval_seconds",
        "is_empty", "lane", "language", "latency_ms", "level", "log_level",
        "max_file_bytes", "mlx_active_bytes", "mlx_cache_bytes", "mlx_peak_bytes",
        "mode", "model_mode", "nemotron_loaded",
        "os_version", "outcome", "parakeet_empty", "parakeet_loaded",
        "peak_rms", "physical_footprint_bytes", "physical_memory_bytes",
        "queue_wait_max_ms", "queue_wait_ms", "queue_wait_p95_ms", "reason",
        "recording_wall_ms", "repository", "resident_bytes",
        "result_empty", "reused", "revision", "sample_count",
        "samples", "source", "state", "step_index", "stop_to_complete_ms",
        "success", "system_cpu_seconds", "target_sample_rate", "to_mode",
        "total_gb", "trigger_mode", "ui_testing", "user_cpu_seconds",
        "vad_available", "vad_enabled", "vad_ms", "vad_p95_ms", "verification",
        "version", "warmup_ms",
    ]

    private let queue = DispatchQueue(label: "saymark.diagnostics", qos: .utility)
    private let stateLock = NSLock()
    private let unifiedLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.eloe.saymark",
        category: "diagnostics"
    )
    private var configuration: SaymarkDiagnosticsConfiguration?

    var level: SaymarkLogLevel {
        stateLock.withLock { configuration?.level ?? .off }
    }

    var fileURL: URL? {
        stateLock.withLock { configuration?.fileURL }
    }

    func configure(_ configuration: SaymarkDiagnosticsConfiguration) {
        stateLock.withLock { self.configuration = configuration }
        queue.async { [weak self] in self?.prepareFile(configuration) }
    }

    func isEnabled(_ messageLevel: SaymarkLogLevel) -> Bool {
        let configured = level
        return messageLevel != .off && configured != .off && messageLevel.rawValue <= configured.rawValue
    }

    func log(
        _ messageLevel: SaymarkLogLevel,
        event: String,
        sessionID: String?,
        fields: [String: Any]
    ) {
        guard isEnabled(messageLevel) else { return }
        // Do not permit a similarly named dynamic event to inherit the normal
        // logger's broad metrics vocabulary.  History diagnostics are closed.
        if event.hasPrefix("history") && !Self.isClosedHistoryEvent(event, fields: fields) { return }

        var object: [String: Any] = [
            "schema": 1,
            "timestamp": Date().timeIntervalSince1970,
            "uptime_ms": ProcessInfo.processInfo.systemUptime * 1_000,
            "level": messageLevel.name,
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        if let sessionID, Self.isOpaqueSessionID(sessionID) { object["session_id"] = sessionID }
        for (key, value) in fields
        where Self.allowedFieldNames.contains(key) && Self.isSafeFieldValue(value, for: key) {
            object[key] = value
        }
        guard JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: encoded, encoding: .utf8)
        else { return }

        switch messageLevel {
        case .error: unifiedLog.error("\(line, privacy: .public)")
        case .warn: unifiedLog.warning("\(line, privacy: .public)")
        case .info: unifiedLog.info("\(line, privacy: .public)")
        case .debug: unifiedLog.debug("\(line, privacy: .public)")
        case .trace: unifiedLog.trace("\(line, privacy: .public)")
        case .off: break
        }

        let data = encoded + Data([0x0A])
        queue.async { [weak self] in self?.append(data) }
    }

    private static func isClosedHistoryEvent(_ event: String, fields: [String: Any]) -> Bool {
        guard event == "history.operation",
              Set(fields.keys).isSubset(of: [
                "history_operation", "history_outcome", "history_retention",
                "history_result_count", "history_duration_ms",
              ]),
              fields["history_operation"] != nil,
              fields["history_outcome"] != nil,
              let operation = fields["history_operation"] as? String,
              let outcome = fields["history_outcome"] as? String
        else { return false }
        guard HistoryDiagnosticOperation(rawValue: operation) != nil,
              HistoryDiagnosticOutcome(rawValue: outcome) != nil
        else { return false }
        if let retention = fields["history_retention"] {
            guard let retention = retention as? String,
                  HistoryRetentionPolicy(rawValue: retention) != nil
            else { return false }
        }
        if let resultCount = fields["history_result_count"] {
            guard let resultCount = resultCount as? Int, (0...25).contains(resultCount) else { return false }
        }
        if let duration = fields["history_duration_ms"] {
            guard let duration = duration as? Int, (0...60_000).contains(duration) else { return false }
        }
        return true
    }

    private func prepareFile(_ configuration: SaymarkDiagnosticsConfiguration) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: configuration.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: configuration.fileURL.path) {
            manager.createFile(atPath: configuration.fileURL.path, contents: nil)
        }
    }

    private func append(_ data: Data) {
        guard let configuration = stateLock.withLock({ self.configuration }),
              configuration.level != .off
        else { return }
        prepareFile(configuration)
        rotateIfNeeded(configuration, adding: data.count)
        guard let handle = try? FileHandle(forWritingTo: configuration.fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            unifiedLog.error("diagnostic file write failed")
        }
    }

    private func rotateIfNeeded(_ configuration: SaymarkDiagnosticsConfiguration, adding bytes: Int) {
        let manager = FileManager.default
        let currentBytes = ((try? manager.attributesOfItem(atPath: configuration.fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard currentBytes + bytes > configuration.maxFileBytes else { return }

        for index in stride(from: configuration.retainedFiles, through: 1, by: -1) {
            let destination = URL(fileURLWithPath: configuration.fileURL.path + ".\(index)")
            let source = index == 1
                ? configuration.fileURL
                : URL(fileURLWithPath: configuration.fileURL.path + ".\(index - 1)")
            try? manager.removeItem(at: destination)
            if manager.fileExists(atPath: source.path) {
                try? manager.moveItem(at: source, to: destination)
            }
        }
        manager.createFile(atPath: configuration.fileURL.path, contents: nil)
    }

    /// String-valued diagnostics are a separate privacy boundary. A field-name
    /// allowlist alone still lets a caller put transcript-like data in `reason`,
    /// `state`, or `destination`; these values are closed enums or bounded,
    /// non-content identifiers. Numbers and booleans remain safe metrics.
    private static func isSafeFieldValue(_ value: Any, for key: String) -> Bool {
        guard let string = value as? String else {
            return value is NSNumber || value is Bool || value is Int ||
                value is Int64 || value is Double || value is Float
        }
        let closedValues: [String: Set<String>] = [
            "reason": ["already_preparing", "dictation_disabled", "dictation_in_flight", "models_not_ready", "accessibility_not_trusted", "secure_input", "paste_failed"],
            "state": ["idle", "recording", "transcribing", "transcribed", "error"],
            "outcome": ["inserted", "copied_accessibility", "insertion_failed", "pending", "success", "failure"],
            "destination": ["onboarding", "menu"],
            "mode": ["accurate", "fast", "hybrid"],
            "model_mode": ["accurate", "fast", "hybrid"],
            "trigger_mode": ["hold", "toggle"],
            "insert_mode": ["in_field", "hud_only"],
            "lane": ["nemotron", "parakeet"],
            "final_source": ["nemotron", "parakeet", "hybrid"],
            "log_level": ["off", "error", "warn", "info", "debug", "trace"],
            "configured_level": ["off", "error", "warn", "info", "debug", "trace"],
            "language": ["auto", "en"],
            "history_operation": Set(HistoryDiagnosticOperation.allRawValues),
            "history_outcome": Set(HistoryDiagnosticOutcome.allRawValues),
            "history_retention": Set(HistoryRetentionPolicy.allCases.map(\.rawValue)),
        ]
        if let values = closedValues[key] { return values.contains(string) }
        switch key {
        case "bundle_id":
            return string == "com.eloe.saymark"
        case "error_type":
            // Stable category names only; localized errors and paths are never
            // diagnostic values.
            return ["Error", "NSError", "CancellationError", "HistoryStoreError"].contains(string)
        case "repository":
            return string.hasPrefix("mlx-community/") && string.count <= 120 && string.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/" || $0 == "." }
        case "version", "build":
            return string.count <= 32 && string.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
        case "os_version":
            return string.hasPrefix("Version ") && string.count <= 80 && string.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        default:
            return false
        }
    }

    private static func isOpaqueSessionID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}

private extension HistoryDiagnosticOperation {
    static var allRawValues: [String] {
        [Self.insert, .query, .delete, .clear, .purge, .policyChange].map(\.rawValue)
    }
}

private extension HistoryDiagnosticOutcome {
    static var allRawValues: [String] {
        [
            Self.success, .unavailable, .corrupt, .migrationFailed,
            .permissionDenied, .busy, .ioFailed, .unsupportedFilesystem,
            .deadlineExceeded, .cleanupIncomplete, .recordTooLarge, .recordLimitReached,
        ].map(\.rawValue)
    }
}
