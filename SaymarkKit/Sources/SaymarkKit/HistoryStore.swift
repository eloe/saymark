import Foundation
import SQLite3
import Darwin

/// The only retention choices understood by the local recent-dictations store.
/// Unknown persisted values must be decoded by the app as `.off`.
public enum HistoryRetentionPolicy: String, CaseIterable, Codable, Sendable {
    case off
    case session
    case days7 = "days_7"
    case days30 = "days_30"
    case days90 = "days_90"
    case untilDeleted = "until_deleted"

    public var durationMilliseconds: Int64? {
        switch self {
        case .days7: return 7 * 24 * 60 * 60 * 1_000
        case .days30: return 30 * 24 * 60 * 60 * 1_000
        case .days90: return 90 * 24 * 60 * 60 * 1_000
        case .off, .session, .untilDeleted: return nil
        }
    }

    public var isEnabled: Bool { self != .off }

    public static func resolved(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .off
    }
}

public enum HistoryDeliveryState: String, CaseIterable, Codable, Sendable {
    case pending
    case inserted
    case copiedAccessibility = "copied_accessibility"
    case insertionFailed = "insertion_failed"

    public var isTerminal: Bool { self != .pending }
}

public struct HistoryFinalization: Sendable, Equatable {
    public let text: String
    public let secureInputActive: Bool
    public let isHUDOnly: Bool

    public init(text: String, secureInputActive: Bool = false, isHUDOnly: Bool = false) {
        self.text = text
        self.secureInputActive = secureInputActive
        self.isHUDOnly = isHUDOnly
    }
}

public struct HistoryRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public let createdAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64?
    public let text: String
    public let deliveryState: HistoryDeliveryState
    public let deliveryUpdatedAtMilliseconds: Int64?
}

public enum HistoryStoreError: Error, Sendable, Equatable {
    case unavailable
    case corrupt
    case migrationFailed
    case permissionDenied
    case busy
    case ioFailed
    case unsupportedFilesystem
    /// The pre-delivery persistence budget elapsed.  This is deliberately a
    /// normal, fail-open outcome rather than a delivery failure.
    case deadlineExceeded
    /// The mutation committed, but SQLite could not prove that its WAL was
    /// truncated.  Callers must not tell a person that removal is complete.
    case cleanupIncomplete
    case recordTooLarge
}

/// UI-independent persistence boundary.  The app owns start/final eligibility
/// snapshots and delivery; this protocol only stores an already-final text.
public protocol HistoryStore: Sendable {
    func recordFinal(_ finalization: HistoryFinalization) async throws -> HistoryRecord?
    func updateDeliveryState(id: String, to state: HistoryDeliveryState) async throws -> Bool
    func records(query: String?, limit: Int) async throws -> [HistoryRecord]
    func delete(id: String) async throws -> Bool
    func clear() async throws
    func setRetentionPolicy(_ policy: HistoryRetentionPolicy) async throws
    func purgeExpired() async throws
}

public extension HistoryStore {
    func records(query: String? = nil, limit: Int = 20) async throws -> [HistoryRecord] {
        try await records(query: query, limit: limit)
    }
}

/// A single-connection, actor-isolated SQLite store.  It deliberately has no
/// AppKit or delivery dependency: callers cannot persist a secure-input or
/// HUD-only final through this boundary.
public actor SQLiteHistoryStore: HistoryStore {
    public static let databaseName = "history.sqlite3"
    public static let maximumFinalTextBytes = 100_000
    public static let defaultResultLimit = 20
    public static let maximumResultLimit = 25

    private let directoryURL: URL
    private let databaseURL: URL
    private let now: @Sendable () -> Int64
    private var database: OpaquePointer?
    private var policy: HistoryRetentionPolicy
    private var inMemoryHighWaterMark: Int64 = 0
    private var generation: UInt64 = 0
    private var lockFileDescriptor: Int32 = -1
    private var activeDeadlineBox: DeadlineBox?

    /// Passing `.off` is intentionally side-effect free: no directory, database,
    /// WAL, or metadata file is created until an explicit enabled policy arrives.
    public init(
        directoryURL: URL,
        policy: HistoryRetentionPolicy = .off,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws {
        self.directoryURL = directoryURL
        self.databaseURL = directoryURL.appendingPathComponent(Self.databaseName, isDirectory: false)
        self.policy = policy
        self.now = now
        // Do not create the store in an initializer.  This preserves the
        // default-Off no-files guarantee even if a caller only constructs a
        // dependency container and never records a final transcript.
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
        if lockFileDescriptor >= 0 { close(lockFileDescriptor) }
    }

    public func recordFinal(_ finalization: HistoryFinalization) throws -> HistoryRecord? {
        try recordFinal(finalization, deadlineUptimeNanoseconds: nil)
    }

    /// Stores a final only while the caller's pre-delivery budget remains.  The
    /// deadline is checked before opening, before beginning the transaction and
    /// immediately before commit.  SQLite's progress handler also interrupts a
    /// queued/expensive statement at the same deadline, so a timed-out caller
    /// cannot leave a late record behind.
    public func recordFinal(
        _ finalization: HistoryFinalization,
        deadlineUptimeNanoseconds: UInt64?
    ) throws -> HistoryRecord? {
        guard policy.isEnabled,
              !finalization.secureInputActive,
              !finalization.isHUDOnly,
              !finalization.text.isEmpty
        else { return nil }
        guard finalization.text.lengthOfBytes(using: .utf8) <= Self.maximumFinalTextBytes else {
            throw HistoryStoreError.recordTooLarge
        }
        try requireBeforeDeadline(deadlineUptimeNanoseconds)
        activeDeadlineBox = deadlineUptimeNanoseconds.map(DeadlineBox.init)
        defer {
            activeDeadlineBox = nil
            if let database { sqlite3_progress_handler(database, 0, nil, nil) }
        }
        try openIfNeeded()
        installDeadlineProgressHandler()

        let effectiveNow = try advanceHighWaterMarkForMutation()
        let id = UUID().uuidString.lowercased()
        let expiry = policy.durationMilliseconds.map { effectiveNow + $0 }
        try transaction(deadlineUptimeNanoseconds) {
            let statement = try prepare("""
                INSERT INTO records (id, created_at_ms, expires_at_ms, text, delivery_state, delivery_updated_at_ms)
                VALUES (?, ?, ?, ?, 'pending', NULL)
                """)
            defer { sqlite3_finalize(statement) }
            try bind(id, to: statement, at: 1)
            try bind(effectiveNow, to: statement, at: 2)
            try bind(expiry, to: statement, at: 3)
            try bind(finalization.text, to: statement, at: 4)
            try stepDone(statement)
        }
        generation &+= 1
        return HistoryRecord(
            id: id, createdAtMilliseconds: effectiveNow, expiresAtMilliseconds: expiry,
            text: finalization.text, deliveryState: .pending, deliveryUpdatedAtMilliseconds: nil
        )
    }

    public func updateDeliveryState(id: String, to state: HistoryDeliveryState) throws -> Bool {
        guard state.isTerminal, policy.isEnabled else { return false }
        try openIfNeeded()
        let updatedAt = try advanceHighWaterMarkForMutation()
        let changes = try transaction {
            let statement = try prepare("""
                UPDATE records SET delivery_state = ?, delivery_updated_at_ms = ?
                WHERE id = ? AND delivery_state = 'pending'
                """)
            defer { sqlite3_finalize(statement) }
            try bind(state.rawValue, to: statement, at: 1)
            try bind(updatedAt, to: statement, at: 2)
            try bind(id, to: statement, at: 3)
            try stepDone(statement)
            return sqlite3_changes(database)
        }
        if changes > 0 { generation &+= 1 }
        return changes > 0
    }

    public func records(query: String? = nil, limit: Int = 20) throws -> [HistoryRecord] {
        guard policy.isEnabled else { return [] }
        try openIfNeeded()
        let effectiveNow = try readEffectiveNow()
        let boundedLimit = min(max(limit, 1), Self.maximumResultLimit)
        let tokens = Self.literalTokens(query ?? "")
        let sql: String
        if tokens.isEmpty {
            sql = """
                SELECT id, created_at_ms, expires_at_ms, text, delivery_state, delivery_updated_at_ms
                FROM records WHERE expires_at_ms IS NULL OR expires_at_ms > ?
                ORDER BY created_at_ms DESC, id DESC LIMIT ?
                """
        } else {
            sql = """
                SELECT r.id, r.created_at_ms, r.expires_at_ms, r.text, r.delivery_state, r.delivery_updated_at_ms
                FROM records AS r JOIN records_fts AS f ON f.rowid = r.rowid
                WHERE records_fts MATCH ? AND (r.expires_at_ms IS NULL OR r.expires_at_ms > ?)
                ORDER BY r.created_at_ms DESC, r.id DESC LIMIT ?
                """
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if !tokens.isEmpty {
            try bind(Self.ftsQuery(tokens), to: statement, at: index)
            index += 1
        }
        try bind(effectiveNow, to: statement, at: index)
        try bind(Int64(boundedLimit), to: statement, at: index + 1)
        var output: [HistoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let textPointer = sqlite3_column_text(statement, 3),
                  let statePointer = sqlite3_column_text(statement, 4),
                  let state = HistoryDeliveryState(rawValue: String(cString: statePointer))
            else { throw HistoryStoreError.corrupt }
            output.append(HistoryRecord(
                id: String(cString: idPointer),
                createdAtMilliseconds: sqlite3_column_int64(statement, 1),
                expiresAtMilliseconds: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2),
                text: String(cString: textPointer),
                deliveryState: state,
                deliveryUpdatedAtMilliseconds: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 5)
            ))
        }
        let result = sqlite3_errcode(database)
        guard result == SQLITE_DONE else { throw mapSQLiteError(result) }
        return output
    }

    public func delete(id: String) throws -> Bool {
        guard policy.isEnabled else { return false }
        try openIfNeeded()
        let changes = try transaction {
            let statement = try prepare("DELETE FROM records WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id, to: statement, at: 1)
            try stepDone(statement)
            return sqlite3_changes(database)
        }
        if changes > 0 {
            try checkpointAfterDeletion()
            generation &+= 1
        }
        return changes > 0
    }

    public func clear() throws {
        guard policy.isEnabled else { return }
        try openIfNeeded()
        try transaction { try execute("DELETE FROM records") }
        try checkpointAfterDeletion()
        generation &+= 1
    }

    public func setRetentionPolicy(_ policy: HistoryRetentionPolicy) throws {
        if policy == .off {
            try clear()
            self.policy = .off
            closeDatabase()
            // The store owns this exact directory.  Removing it after a
            // truncating checkpoint restores the strict Off/no-store state;
            // it does not make an unsupported forensic-erasure claim.
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                do {
                    try FileManager.default.removeItem(at: directoryURL)
                } catch {
                    throw HistoryStoreError.ioFailed
                }
            }
            return
        }
        self.policy = policy
        try openIfNeeded()
        try persistPolicyAndPurge(policy)
        generation &+= 1
    }

    public func purgeExpired() throws {
        guard policy.isEnabled else { return }
        try openIfNeeded()
        let effectiveNow = try advanceHighWaterMarkForMutation()
        try transaction {
            let statement = try prepare("DELETE FROM records WHERE expires_at_ms IS NOT NULL AND expires_at_ms <= ?")
            defer { sqlite3_finalize(statement) }
            try bind(effectiveNow, to: statement, at: 1)
            try stepDone(statement)
        }
        try checkpointAfterDeletion()
        generation &+= 1
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        try createProtectedDirectory()
        try acquireAdvisoryLock()
        try validateExistingDatabaseFile()
        var handle: OpaquePointer?
        // SQLite opens the database itself, but the surrounding directory and
        // file are verified before and after.  NOFOLLOW is used when the
        // platform SQLite exposes it; this is intentionally fail-closed on
        // platforms where protected local storage cannot be established.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw HistoryStoreError.ioFailed
        }
        database = handle
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA journal_size_limit = 0")
            try execute("PRAGMA temp_store = MEMORY")
            try verifySecureDelete()
            try validateDatabaseIdentity()
            try createSchema()
            try protectSQLiteArtifacts()
            try verifyProtectedSQLiteArtifacts()
            inMemoryHighWaterMark = try storedHighWaterMark()
            try persistPolicyAndPurge(policy)
        } catch {
            closeDatabase()
            throw error
        }
    }

    private func createProtectedDirectory() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            // Do not inherit broad permissions from Application Support.  The
            // final directory is private and re-checked before every open.
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try verifyDirectory(directoryURL)
        var directory = directoryURL
        try directory.setResourceValues(values)
        let marker = directoryURL.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
    }

    private func createSchema() throws {
        try execute("PRAGMA application_id = 1396788296") // 'SMHX'
        try execute("""
            CREATE TABLE IF NOT EXISTS store_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS records (
                id TEXT PRIMARY KEY NOT NULL,
                created_at_ms INTEGER NOT NULL,
                expires_at_ms INTEGER,
                text TEXT NOT NULL CHECK(length(text) > 0),
                delivery_state TEXT NOT NULL CHECK(delivery_state IN ('pending', 'inserted', 'copied_accessibility', 'insertion_failed')),
                delivery_updated_at_ms INTEGER
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS records_created_at ON records(created_at_ms DESC, id DESC)")
        try execute("CREATE INDEX IF NOT EXISTS records_expiry ON records(expires_at_ms)")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(text, content='records', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')")
        // FTS has shadow tables with their own deleted-term retention.  Enabling
        // its secure-delete mode is mandatory; if a supported SQLite build does
        // not provide it, opening history fails rather than overstating erasure.
        try execute("INSERT INTO records_fts(records_fts, rank) VALUES('secure-delete', 1)")
        try execute("""
            CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records BEGIN
                INSERT INTO records_fts(rowid, text) VALUES (new.rowid, new.text);
            END
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records BEGIN
                INSERT INTO records_fts(records_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
            END
            """)
        try execute("PRAGMA user_version = 1")
        try execute("INSERT OR IGNORE INTO store_metadata(key, value) VALUES ('last_observed_now_ms', '0')")
        try execute("INSERT OR IGNORE INTO store_metadata(key, value) VALUES ('retention_policy', 'off')")
    }

    private func persistPolicyAndPurge(_ policy: HistoryRetentionPolicy) throws {
        let effectiveNow = try advanceHighWaterMarkForMutation()
        try transaction {
            try metadataSet("retention_policy", policy.rawValue)
            switch policy {
            case .session:
                try execute("DELETE FROM records")
            case .days7, .days30, .days90:
                let duration = policy.durationMilliseconds!
                let statement = try prepare("""
                    UPDATE records SET expires_at_ms = MIN(COALESCE(expires_at_ms, 9223372036854775807), created_at_ms + ?)
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(duration, to: statement, at: 1)
                try stepDone(statement)
                let delete = try prepare("DELETE FROM records WHERE expires_at_ms IS NOT NULL AND expires_at_ms <= ?")
                defer { sqlite3_finalize(delete) }
                try bind(effectiveNow, to: delete, at: 1)
                try stepDone(delete)
            case .untilDeleted:
                break // Existing bounded rows are deliberately never extended.
            case .off:
                try execute("DELETE FROM records")
            }
        }
        try checkpointAfterDeletion()
    }

    private func advanceHighWaterMarkForMutation() throws -> Int64 {
        let effective = max(now(), inMemoryHighWaterMark, try storedHighWaterMark())
        try transaction { try metadataSet("last_observed_now_ms", String(effective)) }
        inMemoryHighWaterMark = effective
        return effective
    }

    private func readEffectiveNow() throws -> Int64 {
        let effective = max(now(), inMemoryHighWaterMark, try storedHighWaterMark())
        inMemoryHighWaterMark = effective
        return effective
    }

    private func storedHighWaterMark() throws -> Int64 {
        let statement = try prepare("SELECT value FROM store_metadata WHERE key = 'last_observed_now_ms'")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0), let result = Int64(String(cString: value)) else {
            throw HistoryStoreError.corrupt
        }
        return result
    }

    private func metadataSet(_ key: String, _ value: String) throws {
        let statement = try prepare("INSERT INTO store_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        try bind(value, to: statement, at: 2)
        try stepDone(statement)
    }

    private func checkpointAfterDeletion() throws {
        let statement = try prepare("PRAGMA wal_checkpoint(TRUNCATE)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw mapSQLiteError(sqlite3_errcode(database)) }
        // SQLite reports (busy, log frames, checkpointed frames).  A busy result
        // means plaintext may remain in the WAL; surface an honest incomplete
        // cleanup state instead of claiming Clear/Off completed.
        guard sqlite3_column_int(statement, 0) == 0 else { throw HistoryStoreError.cleanupIncomplete }
    }

    private func verifySecureDelete() throws {
        let statement = try prepare("PRAGMA secure_delete")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else {
            throw HistoryStoreError.permissionDenied
        }
    }

    private func transaction<T>(_ deadlineUptimeNanoseconds: UInt64? = nil, _ body: () throws -> T) throws -> T {
        try requireBeforeDeadline(deadlineUptimeNanoseconds)
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try requireBeforeDeadline(deadlineUptimeNanoseconds)
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(database))
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(database))
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(database))
        }
    }

    private func bind(_ value: Int64, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw mapSQLiteError(sqlite3_errcode(database))
        }
    }

    private func bind(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) throws {
        if let value { try bind(value, to: statement, at: index); return }
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw mapSQLiteError(sqlite3_errcode(database)) }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw mapSQLiteError(sqlite3_errcode(database)) }
    }

    private func closeDatabase() {
        if let database { sqlite3_close_v2(database) }
        database = nil
        if lockFileDescriptor >= 0 {
            close(lockFileDescriptor)
            lockFileDescriptor = -1
        }
    }

    private func mapSQLiteError(_ code: Int32) -> HistoryStoreError {
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_INTERRUPT: return .deadlineExceeded
        case SQLITE_PERM, SQLITE_AUTH: return .permissionDenied
        case SQLITE_CORRUPT, SQLITE_NOTADB: return .corrupt
        case SQLITE_IOERR, SQLITE_FULL, SQLITE_CANTOPEN: return .ioFailed
        default: return .unavailable
        }
    }

    /// Build only implementation-authored FTS grammar.  Every user token is
    /// quoted and the wildcard is outside that quote, so FTS operators remain
    /// literal search text rather than executable grammar.
    private static func ftsQuery(_ tokens: [String]) -> String {
        tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
    }

    /// Mirrors the unicode61 notion of a word closely enough to avoid exposing
    /// any punctuation or FTS operators as grammar. The FTS layer remains the
    /// authority for case/diacritic folding and matching.
    private static func literalTokens(_ query: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let parts = query.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        var seen = Set<String>()
        return parts.filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
    }

    private func requireBeforeDeadline(_ deadline: UInt64?) throws {
        guard let deadline else { return }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw HistoryStoreError.deadlineExceeded
        }
    }

    private func installDeadlineProgressHandler() {
        guard let database, let deadline = activeDeadlineBox else { return }
        sqlite3_progress_handler(database, 100, { context in
            let deadline = Unmanaged<DeadlineBox>.fromOpaque(context!).takeUnretainedValue()
            return DispatchTime.now().uptimeNanoseconds >= deadline.nanoseconds ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
    }

    private func verifyDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw HistoryStoreError.unsupportedFilesystem }
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        guard mode.map({ ($0 & 0o077) == 0 }) == true else { throw HistoryStoreError.permissionDenied }
    }

    private func validateExistingDatabaseFile() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        let values = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw HistoryStoreError.unsupportedFilesystem }
        let mode = (try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber)?.intValue
        guard mode.map({ ($0 & 0o077) == 0 }) == true else { throw HistoryStoreError.permissionDenied }
    }

    private func acquireAdvisoryLock() throws {
        guard lockFileDescriptor < 0 else { return }
        let lockURL = directoryURL.appendingPathComponent(".history.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw HistoryStoreError.busy
        }
        lockFileDescriptor = descriptor
    }

    private func validateDatabaseIdentity() throws {
        let applicationID = try pragmaInt("application_id")
        guard applicationID == 0 || applicationID == 1_396_788_296 else { throw HistoryStoreError.corrupt }
        let version = try pragmaInt("user_version")
        guard version == 0 || version == 1 else { throw HistoryStoreError.migrationFailed }
    }

    private func pragmaInt(_ name: String) throws -> Int32 {
        let statement = try prepare("PRAGMA \(name)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw mapSQLiteError(sqlite3_errcode(database)) }
        return sqlite3_column_int(statement, 0)
    }

    private func verifyProtectedSQLiteArtifacts() throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw HistoryStoreError.unsupportedFilesystem }
            let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            guard mode.map({ ($0 & 0o077) == 0 }) == true else { throw HistoryStoreError.permissionDenied }
        }
    }

    private func protectSQLiteArtifacts() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

/// A tiny immutable object lets SQLite's C progress callback check a deadline
/// without touching actor-isolated state.
private final class DeadlineBox: @unchecked Sendable {
    let nanoseconds: UInt64
    init(_ nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
