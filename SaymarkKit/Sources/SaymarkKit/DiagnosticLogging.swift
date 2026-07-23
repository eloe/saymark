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
/// in `fields`. Character/word counts and timing measurements are safe.
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
}

private final class DiagnosticStorage: @unchecked Sendable {
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

        var object: [String: Any] = [
            "schema": 1,
            "timestamp": Date().timeIntervalSince1970,
            "uptime_ms": ProcessInfo.processInfo.systemUptime * 1_000,
            "level": messageLevel.name,
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        if let sessionID { object["session_id"] = sessionID }
        for (key, value) in fields where Self.isJSONScalar(value) {
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
            unifiedLog.error("diagnostic file write failed: \(error.localizedDescription, privacy: .public)")
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

    private static func isJSONScalar(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is Bool || value is Int ||
            value is Int64 || value is Double || value is Float
    }
}
