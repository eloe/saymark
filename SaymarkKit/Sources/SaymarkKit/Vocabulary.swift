import Foundation

/// An explicit, local post-ASR rule. `heard` contains ASR output phrases, not
/// pronunciations and never reaches a model or diagnostics.
public struct VocabularyEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case vocabulary, replacement }

    public let id: UUID
    public var kind: Kind
    public var written: String
    public var heard: [String]
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), kind: Kind = .vocabulary, written: String,
        heard: [String], enabled: Bool = true, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.kind = kind; self.written = written; self.heard = heard
        self.enabled = enabled; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct VocabularyDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var unicodeVersion: String
    public var revision: UInt64
    public var entries: [VocabularyEntry]

    public init(revision: UInt64 = 0, entries: [VocabularyEntry] = []) {
        self.schemaVersion = Self.schemaVersion
        self.unicodeVersion = Unicode15_1.version
        self.revision = revision
        self.entries = entries
    }
}

public enum VocabularyValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSchema, unsupportedUnicodeVersion(String), invalidEntry(UUID, String)
    case duplicateID(UUID), duplicateEnabledTrigger(String), entryLimitExceeded, aliasLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidSchema: return "This vocabulary file uses an unsupported format."
        case let .unsupportedUnicodeVersion(version): return "Unicode \(version) is not supported by this Saymark version."
        case let .invalidEntry(_, reason): return reason
        case .duplicateID: return "Each vocabulary entry must have a unique identifier."
        case .duplicateEnabledTrigger: return "Two enabled rules cannot use the same “When I say” phrase."
        case .entryLimitExceeded: return "Vocabulary is limited to 5,000 entries."
        case .aliasLimitExceeded: return "Vocabulary is limited to 20,000 “When I say” phrases."
        }
    }
}

/// The only normalization path used by validation and matching. It deliberately
/// uses Saymark's checked-in Unicode tables rather than Foundation/host ICU.
public enum VocabularyNormalization {
    public static func matchKey(_ text: String) -> String {
        tokens(in: text).map(\.key).joined(separator: " ")
    }

    fileprivate struct Token: Sendable {
        let scalarRange: Range<Int>
        let key: String
    }

    fileprivate static func tokens(in text: String) -> [Token] {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        var tokens: [Token] = []
        var index = 0
        while index < scalars.count {
            guard isWord(scalars[index].value) else { index += 1; continue }
            let start = index
            index += 1
            while index < scalars.count {
                let value = scalars[index].value
                if isWord(value) { index += 1; continue }
                // Apostrophes join a word only when they have a word scalar on
                // both sides. This makes `mark's` one token, but `mark` never
                // matches inside it.
                if (value == 0x27 || value == 0x2019), index + 1 < scalars.count,
                   isWord(scalars[index + 1].value) {
                    index += 2; continue
                }
                break
            }
            let raw = String(String.UnicodeScalarView(scalars[start..<index]))
            let key = Unicode15_1.nfkcCaseFold(raw)
                .unicodeScalars.map { isWhitespace($0.value) ? " " : String($0) }
                .joined().split(whereSeparator: { $0 == " " }).joined(separator: " ")
            if !key.isEmpty { tokens.append(Token(scalarRange: start..<index, key: key)) }
        }
        return tokens
    }

    private static func isWord(_ scalar: UInt32) -> Bool {
        switch Unicode15_1.wordBreakProperty(scalar) {
        case .aLetter, .hebrewLetter, .numeric, .katakana, .extendNumLet: return true
        default: return false
        }
    }

    /// Pinned whitespace policy for match keys. This is intentionally not
    /// `CharacterSet.whitespacesAndNewlines`, whose contents are host ICU data.
    private static func isWhitespace(_ scalar: UInt32) -> Bool {
        scalar == 0x09 || scalar == 0x0A || scalar == 0x0B || scalar == 0x0C || scalar == 0x0D ||
            scalar == 0x20 || scalar == 0x85 || scalar == 0xA0 || scalar == 0x1680 ||
            (0x2000...0x200A).contains(scalar) || scalar == 0x2028 || scalar == 0x2029 ||
            scalar == 0x202F || scalar == 0x205F || scalar == 0x3000
    }
}

public enum VocabularyValidator {
    public static let maxEntries = 5_000
    public static let maxAliases = 20_000
    public static let maxScalars = 256

    public static func validate(_ document: VocabularyDocument) throws {
        guard document.schemaVersion == VocabularyDocument.schemaVersion else { throw VocabularyValidationError.invalidSchema }
        guard document.unicodeVersion == Unicode15_1.version else { throw VocabularyValidationError.unsupportedUnicodeVersion(document.unicodeVersion) }
        guard document.entries.count <= maxEntries else { throw VocabularyValidationError.entryLimitExceeded }
        var ids = Set<UUID>(), aliases = 0, enabledKeys = Set<String>()
        for entry in document.entries {
            guard ids.insert(entry.id).inserted else { throw VocabularyValidationError.duplicateID(entry.id) }
            try validate(entry)
            aliases += entry.heard.count
            guard aliases <= maxAliases else { throw VocabularyValidationError.aliasLimitExceeded }
            if entry.enabled {
                for heard in entry.heard {
                    let key = VocabularyNormalization.matchKey(heard)
                    guard enabledKeys.insert(key).inserted else { throw VocabularyValidationError.duplicateEnabledTrigger(key) }
                }
            }
        }
    }

    public static func validate(_ entry: VocabularyEntry) throws {
        try validate(value: entry.written, entryID: entry.id, field: "Write")
        guard (1...16).contains(entry.heard.count) else {
            throw VocabularyValidationError.invalidEntry(entry.id, "Each rule needs between one and sixteen “When I say” phrases.")
        }
        var keys = Set<String>()
        for heard in entry.heard {
            try validate(value: heard, entryID: entry.id, field: "When I say")
            let key = VocabularyNormalization.matchKey(heard)
            guard !key.isEmpty else { throw VocabularyValidationError.invalidEntry(entry.id, "A “When I say” phrase cannot be blank.") }
            guard keys.insert(key).inserted else { throw VocabularyValidationError.invalidEntry(entry.id, "A rule cannot repeat the same “When I say” phrase.") }
        }
    }

    private static func validate(value: String, entryID: UUID, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.unicodeScalars.count <= maxScalars else {
            throw VocabularyValidationError.invalidEntry(entryID, "\(field) must be non-empty and no longer than 256 Unicode scalars.")
        }
        for scalar in value.unicodeScalars where isUnsafe(scalar.value) {
            throw VocabularyValidationError.invalidEntry(entryID, "\(field) contains an unsafe invisible or control character.")
        }
    }

    // Controls, bidi controls/isolates, zero-width/default-ignorable values
    // that could make the displayed rule differ from what gets inserted.
    private static func isUnsafe(_ value: UInt32) -> Bool {
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        if (0x200B...0x200F).contains(value) || (0x202A...0x202E).contains(value) ||
            (0x2060...0x206F).contains(value) || value == 0xFEFF { return true }
        return false
    }
}

/// Immutable rules captured at dictation start. The implementation is token
/// based, leftmost-longest and single-pass: inserted output is never re-read.
public struct VocabularySnapshot: Sendable, Equatable {
    public let revision: UInt64
    private let rules: [Rule]

    private struct Rule: Sendable, Equatable {
        let keys: [String]
        let written: String
    }

    public init(document: VocabularyDocument = VocabularyDocument()) throws {
        try VocabularyValidator.validate(document)
        revision = document.revision
        rules = document.entries.filter(\.enabled).flatMap { entry in
            entry.heard.map { Rule(keys: VocabularyNormalization.tokens(in: $0).map(\.key), written: entry.written) }
        }
    }

    public static let empty = try! VocabularySnapshot()

    public func correct(_ rawText: String) -> CorrectedTranscript {
        let tokens = VocabularyNormalization.tokens(in: rawText)
        guard !tokens.isEmpty, !rules.isEmpty else {
            return CorrectedTranscript(rawText: rawText, renderedText: rawText, snapshotRevision: revision, appliedRuleCount: 0)
        }
        let scalars = Array(rawText.unicodeScalars)
        var output = "", cursor = 0, tokenIndex = 0, applied = 0
        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex]
            var winner: Rule?
            for rule in rules where rule.keys.count <= tokens.count - tokenIndex {
                guard rule.keys.enumerated().allSatisfy({ tokens[tokenIndex + $0.offset].key == $0.element }) else { continue }
                if winner == nil || rule.keys.count > winner!.keys.count { winner = rule }
            }
            guard let winner else { tokenIndex += 1; continue }
            let endToken = tokens[tokenIndex + winner.keys.count - 1]
            output += String(String.UnicodeScalarView(scalars[cursor..<token.scalarRange.lowerBound]))
            output += winner.written
            cursor = endToken.scalarRange.upperBound
            tokenIndex += winner.keys.count
            applied += 1
        }
        output += String(String.UnicodeScalarView(scalars[cursor..<scalars.count]))
        return CorrectedTranscript(rawText: rawText, renderedText: output, snapshotRevision: revision, appliedRuleCount: applied)
    }
}

public struct CorrectedTranscript: Sendable, Equatable {
    public let rawText: String
    public let renderedText: String
    public let snapshotRevision: UInt64
    public let appliedRuleCount: Int
}

/// Durable, local vocabulary document. The store never logs rule or transcript
/// values. Its snapshot is a value type, so an in-flight dictation cannot observe
/// settings mutations.
public final class VocabularyStore: @unchecked Sendable {
    public static let defaultFilename = "vocabulary.json"
    private let lock = NSLock()
    private let primaryURL: URL
    private let backupURL: URL
    private var document: VocabularyDocument
    public private(set) var readOnlyReason: String?

    public init(directoryURL: URL, filename: String = defaultFilename) throws {
        primaryURL = directoryURL.appendingPathComponent(filename)
        backupURL = directoryURL.appendingPathComponent(filename + ".backup")
        document = VocabularyDocument()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try load()
    }

    public static func applicationSupportURL(bundleIdentifier: String = "com.eloe.saymark") -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public func snapshot() -> VocabularySnapshot { lock.withLock { (try? VocabularySnapshot(document: document)) ?? .empty } }
    public func currentDocument() -> VocabularyDocument { lock.withLock { document } }

    public func replace(_ proposed: VocabularyDocument) throws {
        try lock.withLock {
            try replaceLocked(proposed)
        }
    }

    public func upsert(_ entry: VocabularyEntry) throws {
        try lock.withLock {
            var next = document
            if let index = next.entries.firstIndex(where: { $0.id == entry.id }) { next.entries[index] = entry }
            else { next.entries.append(entry) }
            try replaceLocked(next)
        }
    }

    public func delete(id: UUID) throws {
        try lock.withLock {
            var next = document; next.entries.removeAll { $0.id == id }; try replaceLocked(next)
        }
    }

    public func export(to url: URL) throws {
        let data = try encode(lock.withLock { document })
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func importDocument(from url: URL, strategy: VocabularyImportStrategy) throws -> VocabularyImportPreview {
        let imported = try Self.readDocument(at: url)
        return try lock.withLock {
            let result = try reconcile(local: document, imported: imported, strategy: strategy)
            try VocabularyValidator.validate(result.document)
            return result.preview
        }
    }

    public func applyImport(from url: URL, strategy: VocabularyImportStrategy, acknowledgedURLs: Bool) throws {
        let imported = try Self.readDocument(at: url)
        try lock.withLock {
            let result = try reconcile(local: document, imported: imported, strategy: strategy)
            guard !result.preview.containsURL || acknowledgedURLs else {
                throw VocabularyValidationError.invalidEntry(UUID(), "Review and acknowledge URL replacements before importing.")
            }
            try replaceLocked(result.document)
        }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: primaryURL.path) else { return }
        do { document = try Self.readDocument(at: primaryURL) }
        catch {
            // Keep the corrupt document in place for manual recovery; dictionary
            // use fails safely to an empty in-memory snapshot.
            document = VocabularyDocument()
            readOnlyReason = "Vocabulary could not be read. The original file was kept for recovery."
        }
    }

    private func replaceLocked(_ proposed: VocabularyDocument) throws {
        guard readOnlyReason == nil else { throw VocabularyValidationError.invalidSchema }
        var next = proposed
        next.revision = document.revision &+ 1
        try VocabularyValidator.validate(next)
        try persist(next)
        document = next
    }

    private func persist(_ next: VocabularyDocument) throws {
        let data = try encode(next)
        let directory = primaryURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".vocabulary-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        if FileManager.default.fileExists(atPath: backupURL.path) { try FileManager.default.removeItem(at: backupURL) }
        if FileManager.default.fileExists(atPath: primaryURL.path) { try FileManager.default.moveItem(at: primaryURL, to: backupURL) }
        try FileManager.default.moveItem(at: temporary, to: primaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primaryURL.path)
    }

    private func encode(_ document: VocabularyDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    private static func readDocument(at url: URL) throws -> VocabularyDocument {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 5 * 1024 * 1024 else { throw VocabularyValidationError.invalidSchema }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 5 * 1024 * 1024, jsonDepth(data) <= 64 else { throw VocabularyValidationError.invalidSchema }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(VocabularyDocument.self, from: data)
        try VocabularyValidator.validate(document)
        return document
    }

    private static func jsonDepth(_ data: Data) -> Int {
        var depth = 0, maxDepth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted { if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { quoted = false }; continue }
            if byte == 0x22 { quoted = true; continue }
            if byte == 0x7B || byte == 0x5B { depth += 1; maxDepth = max(maxDepth, depth) }
            if byte == 0x7D || byte == 0x5D { depth -= 1 }
        }
        return depth == 0 && !quoted ? maxDepth : Int.max
    }
}

public enum VocabularyImportStrategy: Sendable { case mergeByID, replaceAll }
public struct VocabularyImportPreview: Sendable, Equatable {
    public let newCount: Int; public let unchangedCount: Int; public let updatedCount: Int; public let disabledCount: Int
    public let containsURL: Bool; public let diffs: [VocabularyEntryDiff]
}
public struct VocabularyEntryDiff: Sendable, Equatable { public let id: UUID; public let old: VocabularyEntry?; public let new: VocabularyEntry }
private struct ImportResult { let document: VocabularyDocument; let preview: VocabularyImportPreview }

private func reconcile(local: VocabularyDocument, imported: VocabularyDocument, strategy: VocabularyImportStrategy) throws -> ImportResult {
    let base: [VocabularyEntry]
    switch strategy {
    case .replaceAll: base = imported.entries
    case .mergeByID:
        var byID = Dictionary(uniqueKeysWithValues: local.entries.map { ($0.id, $0) })
        for entry in imported.entries { byID[entry.id] = entry }
        base = Array(byID.values)
    }
    var result = VocabularyDocument(revision: local.revision, entries: base)
    result.unicodeVersion = imported.unicodeVersion
    try VocabularyValidator.validate(result)
    let oldByID = Dictionary(uniqueKeysWithValues: local.entries.map { ($0.id, $0) })
    let diffs = base.compactMap { entry -> VocabularyEntryDiff? in oldByID[entry.id] == entry ? nil : VocabularyEntryDiff(id: entry.id, old: oldByID[entry.id], new: entry) }
    let newCount = diffs.filter { $0.old == nil }.count
    let updatedCount = diffs.count - newCount
    let disabledCount = base.filter { !$0.enabled }.count
    let hasURL = diffs.contains { $0.new.written.range(of: #"[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil }
    return ImportResult(document: result, preview: VocabularyImportPreview(newCount: newCount, unchangedCount: base.count - diffs.count, updatedCount: updatedCount, disabledCount: disabledCount, containsURL: hasURL, diffs: diffs))
}

/// Separate from SaymarkDiagnostics and PostHog. With consent, it writes one
/// local aggregate per 100 completed dictations; no text, rule IDs, or session ID.
public final class CorrectionDiagnostics: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0; private var applied = 0
    private let fileURL: URL?; public var enabled: Bool
    public init(fileURL: URL? = nil, enabled: Bool = false) { self.fileURL = fileURL; self.enabled = enabled }
    public func record(_ transcript: CorrectedTranscript) {
        lock.withLock {
            guard enabled else { return }; count += 1; applied += transcript.appliedRuleCount
            guard count == 100 else { return }
            let bucket = applied == 0 ? "0" : applied < 10 ? "1-9" : "10+"
            if let fileURL { try? ("{\\\"schema\\\":1,\\\"correction_bucket\\\":\\\"\(bucket)\\\"}\\n").data(using: .utf8)?.write(to: fileURL, options: .atomic) }
            count = 0; applied = 0
        }
    }
}
