import Foundation
import CryptoKit
import Darwin

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
    public static let schemaVersion = 2
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
    case invalidSchema, unsupportedSchemaVersion(Int), unsupportedUnicodeVersion(String), invalidEntry(UUID, String)
    case duplicateID(UUID), duplicateEnabledTrigger(String), entryLimitExceeded, aliasLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidSchema: return "This vocabulary file uses an unsupported format."
        case let .unsupportedSchemaVersion(version):
            return "This vocabulary file uses newer format version \(version). Update Saymark before editing or exporting it."
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
        let startsSourceSegment: Bool
        let endsSourceSegment: Bool
    }

    fileprivate static func tokens(in text: String) -> [Token] {
        let sourceScalars = Array(text.unicodeScalars)
        guard !sourceScalars.isEmpty else { return [] }

        // Run UAX #29 on the pinned normalized stream, while mapping every
        // normalized scalar back to the complete source segment that produced
        // it. This lets a full compatibility expansion match (㍿ -> 株式会社)
        // without permitting a partial match to consume one source character.
        let sourceBoundaries = Unicode15_1.wordBoundaries(in: text)
        var normalizedScalars: [Unicode.Scalar] = []
        var sourceRanges: [Range<Int>] = []
        var sourceStart = 0
        for sourceEnd in 1...sourceScalars.count where sourceBoundaries[sourceEnd] {
            defer { sourceStart = sourceEnd }
            let sourceRange = sourceStart..<sourceEnd
            let raw = String(String.UnicodeScalarView(sourceScalars[sourceRange]))
            for scalar in Unicode15_1.nfkcCaseFold(raw).unicodeScalars {
                normalizedScalars.append(isWhitespace(scalar.value) ? Unicode.Scalar(0x20)! : scalar)
                sourceRanges.append(sourceRange)
            }
        }
        guard !normalizedScalars.isEmpty else { return [] }
        let normalizedText = String(String.UnicodeScalarView(normalizedScalars))
        let boundaries = Unicode15_1.wordBoundaries(in: normalizedText)
        var tokens: [Token] = []
        var start = 0
        for end in 1...normalizedScalars.count where boundaries[end] {
            defer { start = end }
            guard end > start else { continue }
            let key = String(String.UnicodeScalarView(normalizedScalars[start..<end]))
                .split(whereSeparator: { $0 == " " }).joined(separator: " ")
            // UAX #29 segments punctuation and whitespace too. Keep only its
            // word-bearing segments and preserve their original source span.
            guard key.unicodeScalars.contains(where: { isWord($0.value) }) else { continue }
            if !key.isEmpty {
                tokens.append(Token(
                    scalarRange: sourceRanges[start].lowerBound..<sourceRanges[end - 1].upperBound,
                    key: key,
                    startsSourceSegment: start == 0 || sourceRanges[start - 1] != sourceRanges[start],
                    endsSourceSegment: end == normalizedScalars.count || sourceRanges[end] != sourceRanges[end - 1]
                ))
            }
        }
        return tokens
    }

    private static func isWord(_ scalar: UInt32) -> Bool {
        // Ideographs have `Other` in WordBreakProperty but are independent word
        // units under UAX #29. Keep their original scalar span so compatibility
        // expansions such as ㈱ never admit a partial match.
        if (0x3400...0x4DBF).contains(scalar) || (0x4E00...0x9FFF).contains(scalar) ||
            (0xF900...0xFAFF).contains(scalar) || (0x20000...0x2FA1F).contains(scalar) { return true }
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

    // Controls, bidi controls/isolates, default-ignorables, unassigned values,
    // and noncharacters could make the displayed rule differ from insertion or
    // acquire a new meaning after an OS Unicode update.  This check is pinned
    // to the bundled 15.1 tables and never delegates to host ICU.
    private static func isUnsafe(_ value: UInt32) -> Bool {
        Unicode15_1.isUnsafeVocabularyScalar(value)
    }
}

private enum VocabularyMigration {
    /// Version 1 used the same fields but did not record the durable-store
    /// recovery contract.  Decode it explicitly, upgrade in memory, and write
    /// version 2 only on the next successful transactional save.
    static func migrate(_ document: VocabularyDocument) throws -> VocabularyDocument {
        switch document.schemaVersion {
        case VocabularyDocument.schemaVersion: return document
        case 1:
            var migrated = document
            migrated.schemaVersion = VocabularyDocument.schemaVersion
            return migrated
        case let version where version > VocabularyDocument.schemaVersion:
            throw VocabularyValidationError.unsupportedSchemaVersion(version)
        default:
            throw VocabularyValidationError.invalidSchema
        }
    }
}

/// Immutable rules captured at dictation start. The implementation is token
/// based, leftmost-longest and single-pass: inserted output is never re-read.
public struct VocabularySnapshot: Sendable, Equatable {
    public let revision: UInt64
    private let automaton: TokenAutomaton

    fileprivate struct Rule: Sendable, Equatable {
        let keys: [String]
        let written: String
    }

    public init(document: VocabularyDocument = VocabularyDocument()) throws {
        try VocabularyValidator.validate(document)
        revision = document.revision
        let rules = document.entries.filter(\.enabled).flatMap { entry in
            entry.heard.map { Rule(keys: VocabularyNormalization.tokens(in: $0).map(\.key), written: entry.written) }
        }
        automaton = TokenAutomaton(rules: rules)
    }

    public static let empty = try! VocabularySnapshot()

    public func correct(_ rawText: String) -> CorrectedTranscript {
        let tokens = VocabularyNormalization.tokens(in: rawText)
        guard !tokens.isEmpty, !automaton.isEmpty else {
            return CorrectedTranscript(rawText: rawText, renderedText: rawText, snapshotRevision: revision, appliedRuleCount: 0)
        }
        let scalars = Array(rawText.unicodeScalars)
        // Aho-Corasick finds every candidate in one token pass.  We retain
        // only the longest candidate per start, then emit leftmost-longest.
        // The compiled automaton is immutable and captured with the snapshot.
        let winners = automaton.longestMatches(in: tokens)
        var output = "", cursor = 0, tokenIndex = 0, applied = 0
        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex]
            guard let ruleIndex = winners[tokenIndex] else { tokenIndex += 1; continue }
            let winner = automaton.rule(at: ruleIndex)
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

/// Immutable token Aho-Corasick automaton.  It removes the O(rules × tokens)
/// draft-path scan and is intentionally private so no mutable rule state can
/// escape a frozen utterance snapshot.
private struct TokenAutomaton: Sendable, Equatable {
    private struct Node: Sendable, Equatable {
        var edges: [String: Int] = [:]
        var failure = 0
        var outputs: [Int] = []
    }
    private let nodes: [Node]
    private let rules: [VocabularySnapshot.Rule]
    var isEmpty: Bool { rules.isEmpty }

    init(rules: [VocabularySnapshot.Rule]) {
        self.rules = rules
        var built: [Node] = [Node()]
        for (ruleIndex, rule) in rules.enumerated() where !rule.keys.isEmpty {
            var state = 0
            for key in rule.keys {
                if let next = built[state].edges[key] { state = next }
                else {
                    let next = built.count; built.append(Node()); built[state].edges[key] = next; state = next
                }
            }
            built[state].outputs.append(ruleIndex)
        }
        var queue: [Int] = []
        for child in built[0].edges.values { queue.append(child) }
        var cursor = 0
        while cursor < queue.count {
            let state = queue[cursor]; cursor += 1
            for (key, child) in built[state].edges {
                queue.append(child)
                var fallback = built[state].failure
                while fallback != 0 && built[fallback].edges[key] == nil { fallback = built[fallback].failure }
                built[child].failure = built[fallback].edges[key] ?? 0
                built[child].outputs += built[built[child].failure].outputs
            }
        }
        self.nodes = built
    }

    func rule(at index: Int) -> VocabularySnapshot.Rule { rules[index] }

    func longestMatches(in tokens: [VocabularyNormalization.Token]) -> [Int: Int] {
        var matches: [Int: Int] = [:]
        var state = 0
        for (end, token) in tokens.enumerated() {
            let key = token.key
            while state != 0 && nodes[state].edges[key] == nil { state = nodes[state].failure }
            state = nodes[state].edges[key] ?? 0
            for ruleIndex in nodes[state].outputs {
                let rule = rules[ruleIndex]
                let start = end + 1 - rule.keys.count
                guard start >= 0 else { continue }
                guard tokens[start].startsSourceSegment, tokens[end].endsSourceSegment else {
                    continue
                }
                if let old = matches[start], rules[old].keys.count >= rule.keys.count { continue }
                matches[start] = ruleIndex
            }
        }
        return matches
    }
}

public struct CorrectedTranscript: Sendable, Equatable {
    public enum CorrectionStatus: String, Sendable, Equatable { case unchanged, corrected, failedRawFallback }
    public let rawText: String
    public let renderedText: String
    public let snapshotRevision: UInt64
    public let appliedRuleCount: Int
    public let correctionStatus: CorrectionStatus

    public init(rawText: String, renderedText: String, snapshotRevision: UInt64, appliedRuleCount: Int, correctionStatus: CorrectionStatus? = nil) {
        self.rawText = rawText; self.renderedText = renderedText; self.snapshotRevision = snapshotRevision
        self.appliedRuleCount = appliedRuleCount
        self.correctionStatus = correctionStatus ?? (appliedRuleCount == 0 ? .unchanged : .corrected)
    }
}

/// Whole-hypothesis draft scheduler.  At most one correction is running and
/// one newer hypothesis is retained; intermediate drafts are overwritten
/// before work begins.  The caller owns delivery to the UI and can always use
/// `correctFinal` for an authoritative final without waiting behind drafts.
public final class TranscriptCorrectionPipeline: @unchecked Sendable {
    private struct Pending: Sendable {
        let revision: UInt64; let raw: String; let completion: @Sendable (CorrectedTranscript) -> Void
    }
    private let snapshot: VocabularySnapshot
    private let evaluator: @Sendable (String) throws -> CorrectedTranscript
    private let lock = NSRecursiveLock()
    private let worker = DispatchQueue(label: "saymark.correction", qos: .userInitiated)
    private var latest: Pending?
    private var draining = false
    private var nextRevision: UInt64 = 0

    public convenience init(snapshot: VocabularySnapshot) {
        self.init(snapshot: snapshot, evaluator: { snapshot.correct($0) })
    }

    init(snapshot: VocabularySnapshot, evaluator: @escaping @Sendable (String) throws -> CorrectedTranscript) {
        self.snapshot = snapshot; self.evaluator = evaluator
    }

    /// Cheap caller-side capture: only a monotonically increasing revision and
    /// latest raw hypothesis are retained; no tokenization occurs on the STT
    /// queue. Superseded drafts never invoke their completion.
    public func submitDraft(_ raw: String, completion: @escaping @Sendable (CorrectedTranscript) -> Void) {
        lock.withLock {
            nextRevision &+= 1
            latest = Pending(revision: nextRevision, raw: raw, completion: completion)
            guard !draining else { return }
            draining = true
            worker.async { [weak self] in self?.drain() }
        }
    }

    /// Finals are deliberately evaluated directly rather than queued behind a
    /// live draft. This keeps final delivery authoritative and bounded.
    public func correctFinal(_ raw: String) -> CorrectedTranscript {
        // Invalidate any queued draft before final evaluation. A running draft
        // may finish, but its completion observes the generation mismatch.
        lock.withLock { nextRevision &+= 1; latest = nil }
        do { return try evaluator(raw) }
        catch {
            return CorrectedTranscript(rawText: raw, renderedText: raw, snapshotRevision: snapshot.revision,
                                       appliedRuleCount: 0, correctionStatus: .failedRawFallback)
        }
    }

    private func drain() {
        while true {
            guard let pending = lock.withLock({ () -> Pending? in
                let value = latest; latest = nil
                if value == nil { draining = false }
                return value
            }) else { return }
            let result: CorrectedTranscript
            do { result = try evaluator(pending.raw) }
            catch {
                result = CorrectedTranscript(rawText: pending.raw, renderedText: pending.raw,
                                             snapshotRevision: snapshot.revision, appliedRuleCount: 0,
                                             correctionStatus: .failedRawFallback)
            }
            // Generation validation and delivery are one critical section.
            // A newer submit can therefore occur either before this delivery
            // (and suppress it) or after it, never in the gap between a stale
            // check and publication.
            lock.withLock {
                guard latest == nil, pending.revision == nextRevision else { return }
                pending.completion(result)
            }
        }
    }
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
    public private(set) var recoveryMessage: String?

    public init(directoryURL: URL, filename: String = defaultFilename) throws {
        primaryURL = directoryURL.appendingPathComponent(filename)
        backupURL = directoryURL.appendingPathComponent(filename + ".backup")
        document = VocabularyDocument()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
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
        let data = try lock.withLock {
            guard readOnlyReason == nil else { throw VocabularyValidationError.invalidSchema }
            return try encode(document)
        }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func importDocument(from url: URL, strategy: VocabularyImportStrategy) throws -> VocabularyImportPreview {
        let imported = try Self.readDocumentAndToken(at: url)
        return try lock.withLock {
            let result = try reconcile(local: document, imported: imported.document, strategy: strategy, sourceToken: imported.token)
            return result.preview
        }
    }

    public func applyImport(from url: URL, strategy: VocabularyImportStrategy, acknowledgedURLs: Bool, previewToken: String? = nil) throws {
        let (imported, token) = try Self.readDocumentAndToken(at: url)
        try lock.withLock {
            guard previewToken == nil || previewToken == token else {
                throw VocabularyValidationError.invalidEntry(UUID(), "The import file changed after preview. Review it again before importing.")
            }
            let result = try reconcile(local: document, imported: imported, strategy: strategy, sourceToken: token)
            guard !result.preview.containsURL || acknowledgedURLs else {
                throw VocabularyValidationError.invalidEntry(UUID(), "Review and acknowledge URL replacements before importing.")
            }
            try replaceLocked(result.document)
        }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: primaryURL.path) else {
            if let backup = try? Self.readDocument(at: backupURL) {
                document = backup
                recoveryMessage = "Vocabulary was restored from its last complete backup."
            }
            return
        }
        do { document = try Self.readDocument(at: primaryURL) }
        catch let error as VocabularyValidationError {
            if case let .unsupportedSchemaVersion(version) = error {
                // A future schema is valid user data, not corruption. Never
                // replace it with an older backup or permit writes/exports
                // from a misleading fallback document.
                document = VocabularyDocument()
                readOnlyReason = VocabularyValidationError.unsupportedSchemaVersion(version).localizedDescription
                return
            }
            recoverFromBackupOrBecomeReadOnly()
        }
        catch {
            recoverFromBackupOrBecomeReadOnly()
        }
    }

    private func recoverFromBackupOrBecomeReadOnly() {
        // A complete prior version is more useful than a blank vocabulary.
        // Never overwrite the damaged primary while recovery is in effect.
        if let backup = try? Self.readDocument(at: backupURL) {
            document = backup
            recoveryMessage = "Vocabulary was restored from its last complete backup."
        } else {
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
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: primaryURL, to: backupURL)
        }
        // When recovering from a backup-only crash point, leave that sole
        // complete backup in place until the new primary is installed.
        try FileManager.default.moveItem(at: temporary, to: primaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primaryURL.path)
        // `rename` alone does not survive a power loss.  Flush both the named
        // file and directory metadata before reporting a successful save.
        let primary = try FileHandle(forReadingFrom: primaryURL); try primary.synchronize(); try primary.close()
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func encode(_ document: VocabularyDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    private static func readDocument(at url: URL) throws -> VocabularyDocument {
        try readDocumentAndToken(at: url).document
    }

    private static func readDocumentAndToken(at url: URL) throws -> (document: VocabularyDocument, token: String) {
        // Open once with O_NOFOLLOW, then validate/read that descriptor.  Path
        // resource checks followed by Data(contentsOf:) have a symlink swap
        // window; this bounds imports to the reviewed regular file instead.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VocabularyValidationError.invalidSchema }
        defer { close(descriptor) }
        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFREG,
              statBuffer.st_size >= 0, statBuffer.st_size <= 5 * 1024 * 1024 else {
            throw VocabularyValidationError.invalidSchema
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data(); data.reserveCapacity(min(Int(statBuffer.st_size), 64 * 1024))
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count <= 5 * 1024 * 1024 - chunk.count else { throw VocabularyValidationError.invalidSchema }
            data.append(chunk)
        }
        guard data.count <= 5 * 1024 * 1024, jsonDepth(data) <= 64, hasNoDuplicateObjectKeys(data) else { throw VocabularyValidationError.invalidSchema }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try VocabularyMigration.migrate(decoder.decode(VocabularyDocument.self, from: data))
        try VocabularyValidator.validate(document)
        return (document, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
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

    /// Reject duplicate keys before Codable collapses them.  The scanner only
    /// records a quoted string as a key when it is immediately followed by a
    /// colon, and tracks keys per object, so repeated `id` fields in separate
    /// entries remain valid.
    private static func hasNoDuplicateObjectKeys(_ data: Data) -> Bool {
        var stack: [Set<String>?] = [], index = 0
        func skipSpace() { while index < data.count && [9, 10, 13, 32].contains(data[index]) { index += 1 } }
        func string() -> String? {
            guard index < data.count, data[index] == 34 else { return nil }; index += 1
            var encoded: [UInt8] = [34]
            while index < data.count {
                let byte = data[index]; index += 1
                encoded.append(byte)
                if byte == 34 { return try? JSONDecoder().decode(String.self, from: Data(encoded)) }
                if byte == 92 { guard index < data.count else { return nil }; encoded.append(data[index]); index += 1 }
            }; return nil
        }
        while index < data.count {
            skipSpace(); guard index < data.count else { break }
            switch data[index] {
            case 123: stack.append([]); index += 1
            case 91: stack.append(nil); index += 1
            case 125, 93: guard !stack.isEmpty else { return false }; stack.removeLast(); index += 1
            case 34:
                guard let value = string() else { return false }; skipSpace()
                if index < data.count, data[index] == 58, case var .some(keys)? = stack.last {
                    guard keys.insert(value).inserted else { return false }; stack[stack.count - 1] = keys
                }
            default: index += 1
            }
        }
        return stack.isEmpty
    }
}

public enum VocabularyImportStrategy: Sendable, Hashable { case mergeByID, replaceAll }
public struct VocabularyImportPreview: Sendable, Equatable {
    public let newCount: Int; public let unchangedCount: Int; public let updatedCount: Int
    public let disabledCount: Int; public let conflictCount: Int
    public let containsURL: Bool; public let sourceToken: String; public let diffs: [VocabularyEntryDiff]
}
public struct VocabularyEntryDiff: Sendable, Equatable {
    public let id: UUID; public let old: VocabularyEntry?; public let new: VocabularyEntry?
    public enum Change: Sendable, Equatable { case added, updated, deleted }
    public var change: Change { old == nil ? .added : new == nil ? .deleted : .updated }
    public var containsURL: Bool { new.map { hasURLScheme($0.written) } ?? false }
}
private struct ImportResult { let document: VocabularyDocument; let preview: VocabularyImportPreview }

private func reconcile(local: VocabularyDocument, imported: VocabularyDocument, strategy: VocabularyImportStrategy, sourceToken: String) throws -> ImportResult {
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
    let oldByID = Dictionary(uniqueKeysWithValues: local.entries.map { ($0.id, $0) })
    var diffs = base.compactMap { entry -> VocabularyEntryDiff? in
        oldByID[entry.id] == entry ? nil : VocabularyEntryDiff(id: entry.id, old: oldByID[entry.id], new: entry)
    }
    if strategy == .replaceAll {
        let incomingIDs = Set(base.map(\.id))
        diffs += local.entries.filter { !incomingIDs.contains($0.id) }.map { VocabularyEntryDiff(id: $0.id, old: $0, new: nil) }
    }
    let newCount = diffs.filter { $0.change == .added }.count
    let updatedCount = diffs.filter { $0.change == .updated }.count
    let disabledCount = base.filter { !$0.enabled }.count
    let hasURL = diffs.contains { $0.containsURL }
    let conflictCount = enabledTriggerConflictCount(in: base)
    let retainedChanges = diffs.filter { $0.new != nil }.count
    return ImportResult(document: result, preview: VocabularyImportPreview(
        newCount: newCount,
        unchangedCount: base.count - retainedChanges,
        updatedCount: updatedCount,
        disabledCount: disabledCount,
        conflictCount: conflictCount,
        containsURL: hasURL,
        sourceToken: sourceToken,
        diffs: diffs
    ))
}

private func hasURLScheme(_ value: String) -> Bool {
    value.range(of: #"\b[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
}

private func enabledTriggerConflictCount(in entries: [VocabularyEntry]) -> Int {
    var seen = Set<String>(), conflicts = 0
    for entry in entries where entry.enabled {
        for heard in entry.heard {
            if !seen.insert(VocabularyNormalization.matchKey(heard)).inserted { conflicts += 1 }
        }
    }
    return conflicts
}

/// Separate, explicit consent for correction aggregates.  This is intentionally
/// not convertible from the app's analytics/PostHog consent.
public struct CorrectionDiagnosticsConsent: Sendable, Equatable {
    public let allowsLocalAggregation: Bool
    public init(allowsLocalAggregation: Bool = false) { self.allowsLocalAggregation = allowsLocalAggregation }
    public static let disabled = CorrectionDiagnosticsConsent()
}

/// Separate from SaymarkDiagnostics and PostHog. With consent, it appends one
/// local aggregate per 100 completed dictations; no text, rule IDs, session ID,
/// or per-utterance measurements are ever materialized.
public final class CorrectionDiagnostics: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0; private var applied = 0
    private let fileURL: URL?; public var consent: CorrectionDiagnosticsConsent
    public var enabled: Bool { consent.allowsLocalAggregation }
    public init(fileURL: URL? = nil, consent: CorrectionDiagnosticsConsent = .disabled) {
        self.fileURL = fileURL; self.consent = consent
    }
    public func record(_ transcript: CorrectedTranscript) {
        lock.withLock {
            guard consent.allowsLocalAggregation else { return }; count += 1; applied += transcript.appliedRuleCount
            guard count == 100 else { return }
            let bucket = applied == 0 ? "0" : applied < 10 ? "1-9" : "10+"
            if let fileURL { try? append(bucket: bucket, to: fileURL) }
            count = 0; applied = 0
        }
    }

    private func append(bucket: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"schema\":1,\"correction_bucket\":\"\(bucket)\"}\n".utf8))
        try handle.synchronize(); try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
