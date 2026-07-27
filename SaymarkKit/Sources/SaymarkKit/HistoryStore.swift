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
    func warmUp() async throws
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
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }
    public static let databaseName = "history.sqlite3"
    public static let maximumFinalTextBytes = 100_000
    public static let maximumSearchQueryBytes = 1_024
    public static let maximumSearchTokens = 12
    public static let defaultResultLimit = 20
    public static let maximumResultLimit = 25
    private static let controlledArtifactNames: Set<String> = [
        databaseName, "\(databaseName)-wal", "\(databaseName)-shm",
        ".history.lock", ".metadata_never_index", ".cleanup-proof",
        ".migration-temp"
    ]

    private let directoryURL: URL
    private let databaseURL: URL
    private let now: @Sendable () -> Int64
    private var database: OpaquePointer?
    private var policy: HistoryRetentionPolicy
    private var inMemoryHighWaterMark: Int64 = 0
    private var generation: UInt64 = 0
    private var cleanupFailureLatched = false
    private var lockFileDescriptor: Int32 = -1
    private let testPreCommitDelayMicroseconds: useconds_t
    private let testCheckpointFailure: Bool
    private let testProofFailure: Bool
    private let testSchemaCreationFailure: Bool

    /// Passing `.off` is intentionally side-effect free: no directory, database,
    /// WAL, or metadata file is created until an explicit enabled policy arrives.
    public init(
        directoryURL: URL,
        policy: HistoryRetentionPolicy = .off,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        testPreCommitDelayMicroseconds: useconds_t = 0,
        testCheckpointFailure: Bool = false,
        testProofFailure: Bool = false,
        testSchemaCreationFailure: Bool = false
    ) throws {
        self.directoryURL = directoryURL
        self.databaseURL = directoryURL.appendingPathComponent(Self.databaseName, isDirectory: false)
        self.policy = policy
        self.now = now
        self.testPreCommitDelayMicroseconds = testPreCommitDelayMicroseconds
        self.testCheckpointFailure = testCheckpointFailure
        self.testProofFailure = testProofFailure
        self.testSchemaCreationFailure = testSchemaCreationFailure
        // Do not create the store in an initializer.  This preserves the
        // default-Off no-files guarantee even if a caller only constructs a
        // dependency container and never records a final transcript.
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
        if lockFileDescriptor >= 0 { close(lockFileDescriptor) }
    }

    /// Opens, validates, and configures the writer while the app is idle. This
    /// intentionally performs no record mutation, so the final-delivery path
    /// does not pay schema or filesystem setup cost.
    public func warmUp() throws {
        guard policy.isEnabled || FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try openIfNeeded()
    }

    /// Reads the transactionally persisted policy. The caller-provided policy
    /// is only a new-store bootstrap value; an existing store always wins.
    public func durableRetentionPolicy() throws -> HistoryRetentionPolicy {
        guard policy.isEnabled || FileManager.default.fileExists(atPath: directoryURL.path) else {
            return .off
        }
        try openIfNeeded()
        let durable = try storedRetentionPolicy()
        // Never reconcile from the bootstrap/cache hint. SQLite metadata is
        // the sole authority, including after a transaction committed but its
        // destructive proof/checkpoint subsequently failed.
        policy = durable
        return durable
    }

    /// Releases the private connection and advisory lock. Primarily useful for
    /// deterministic lifecycle tests and orderly controller shutdown.
    public func shutdown() {
        closeDatabase()
    }

    public func recordFinal(_ finalization: HistoryFinalization) throws -> HistoryRecord? {
        try recordFinal(finalization, deadlineUptimeNanoseconds: nil, cancellation: nil)
    }

    /// Stores a final only while the caller's pre-delivery budget remains.  The
    /// deadline is checked before opening, before beginning the transaction and
    /// immediately before commit.  SQLite's progress handler also interrupts a
    /// queued/expensive statement at the same deadline, so a timed-out caller
    /// cannot leave a late record behind.
    public func recordFinal(
        _ finalization: HistoryFinalization,
        deadlineUptimeNanoseconds: UInt64?,
        cancellation: HistoryWriteCancellation? = nil
    ) throws -> HistoryRecord? {
        try reconcilePolicyBeforeGate()
        guard policy.isEnabled,
              !cleanupFailureLatched,
              !finalization.secureInputActive,
              !finalization.isHUDOnly,
              !finalization.text.isEmpty
        else { return nil }
        guard finalization.text.lengthOfBytes(using: .utf8) <= Self.maximumFinalTextBytes else {
            throw HistoryStoreError.recordTooLarge
        }
        let writeCancellation = cancellation ?? HistoryWriteCancellation()
        try requireBeforeDeadline(deadlineUptimeNanoseconds, cancellation: writeCancellation)
        writeCancellation.begin(deadlineUptimeNanoseconds)
        defer {
            let wasInterrupted = writeCancellation.isInterrupted
            writeCancellation.finish()
            if wasInterrupted {
                // sqlite3_interrupt issued while no VDBE is active can poison
                // the next operation on that connection.  Drop this private
                // connection after rollback so a later read cannot inherit the
                // deadline signal.
                closeDatabase()
            } else if let database {
                sqlite3_progress_handler(database, 0, nil, nil)
            }
        }
        try openIfNeeded()
        if let database { writeCancellation.attach(database) }
        installDeadlineProgressHandler(writeCancellation)

        let effectiveNow = try advanceHighWaterMarkForMutation()
        let id = UUID().uuidString.lowercased()
        let expiry = policy.durationMilliseconds.map { effectiveNow + $0 }
        try transaction(deadlineUptimeNanoseconds, cancellation: writeCancellation) {
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
            // This injection exists solely to make the cancellation contract
            // testable: a delivery deadline must interrupt an in-flight write,
            // roll it back, and never create a late row.
            if testPreCommitDelayMicroseconds > 0 { usleep(testPreCommitDelayMicroseconds) }
        }
        generation &+= 1
        return HistoryRecord(
            id: id, createdAtMilliseconds: effectiveNow, expiresAtMilliseconds: expiry,
            text: finalization.text, deliveryState: .pending, deliveryUpdatedAtMilliseconds: nil
        )
    }

    public func updateDeliveryState(id: String, to state: HistoryDeliveryState) throws -> Bool {
        try reconcilePolicyBeforeGate()
        if cleanupFailureLatched { throw HistoryStoreError.cleanupIncomplete }
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

    /// Protocol witness for the ordinary, non-cancellable store query.
    public func records(query: String? = nil, limit: Int = 20) throws -> [HistoryRecord] {
        try records(query: query, limit: limit, cancellation: nil)
    }

    /// A private-window search can pass its own cancellation token. It is not
    /// part of the general `HistoryStore` contract because background callers
    /// must not be able to interrupt another operation.
    public func records(
        query: String? = nil,
        limit: Int = 20,
        cancellation: HistoryWriteCancellation? = nil
    ) throws -> [HistoryRecord] {
        try reconcilePolicyBeforeGate()
        if cleanupFailureLatched { throw HistoryStoreError.cleanupIncomplete }
        guard policy.isEnabled else { return [] }
        if let query, query.lengthOfBytes(using: .utf8) > Self.maximumSearchQueryBytes {
            throw HistoryStoreError.recordTooLarge
        }
        cancellation?.begin(nil)
        defer {
            cancellation?.finish()
            if let database { sqlite3_progress_handler(database, 0, nil, nil) }
        }
        if cancellation?.isInterrupted == true { throw HistoryStoreError.deadlineExceeded }
        try openIfNeeded()
        if let cancellation, let database {
            cancellation.attach(database)
            installDeadlineProgressHandler(cancellation)
        }
        let effectiveNow = try readEffectiveNow()
        let boundedLimit = min(max(limit, 1), Self.maximumResultLimit)
        let tokens = Array(Self.literalTokens(query ?? "").prefix(Self.maximumSearchTokens))
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
            if cancellation?.isInterrupted == true { throw HistoryStoreError.deadlineExceeded }
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
        try reconcilePolicyBeforeGate()
        if cleanupFailureLatched { throw HistoryStoreError.cleanupIncomplete }
        guard policy.isEnabled else { return false }
        try openIfNeeded()
        let removedText = try textForRecord(id: id)
        let changes = try transaction {
            let statement = try prepare("DELETE FROM records WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id, to: statement, at: 1)
            try stepDone(statement)
            return sqlite3_changes(database)
        }
        if changes > 0 {
            do {
                try checkpointAfterDeletion()
                try verifyRemovedTextIsAbsent(removedText.map { [$0] } ?? [])
                cleanupFailureLatched = false
            } catch {
                cleanupFailureLatched = true
                throw error
            }
            generation &+= 1
        }
        return changes > 0
    }

    public func clear() throws {
        try reconcilePolicyBeforeGate()
        if cleanupFailureLatched { throw HistoryStoreError.cleanupIncomplete }
        guard policy.isEnabled else { return }
        try openIfNeeded()
        let proof = try createCleanupProof()
        defer {
            try? destroyCleanupProof(proof)
            close(proof)
        }
        do {
            try transaction { try execute("DELETE FROM records") }
            try checkpointAfterDeletion()
            try verifyCleanupProof(proof)
            try destroyCleanupProof(proof)
            cleanupFailureLatched = false
        } catch {
            cleanupFailureLatched = true
            throw error
        }
        generation &+= 1
    }

    public func setRetentionPolicy(_ policy: HistoryRetentionPolicy) throws {
        if policy == .off {
            // Off intent closes the write gate immediately and remains
            // fail-closed even if checkpoint/artifact cleanup is incomplete.
            self.policy = .off
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            try openIfNeeded()
            self.policy = .off
            do {
                try persistPolicyAndPurge(.off)
            } catch {
                cleanupFailureLatched = true
                self.policy = .off
                throw error
            }
            cleanupFailureLatched = false
            self.policy = .off
            closeDatabase()
            // The store owns this exact directory.  Removing it after a
            // truncating checkpoint restores the strict Off/no-store state;
            // it does not make an unsupported forensic-erasure claim.
            try removeOwnedStoreDirectory()
            return
        }
        try openIfNeeded()
        do {
            try persistPolicyAndPurge(policy)
        } catch {
            // A policy transaction may have committed before proof/checkpoint
            // failed. Reconcile the cache from SQLite, then latch all history
            // reads/writes closed until a retry/relaunch completes cleanup.
            self.policy = (try? storedRetentionPolicy()) ?? .off
            cleanupFailureLatched = true
            throw error
        }
        // Metadata is the commit authority. Do not publish this in-memory
        // policy until its transaction and truncating checkpoint have passed.
        self.policy = policy
        cleanupFailureLatched = false
        generation &+= 1
    }

    public func purgeExpired() throws {
        try reconcilePolicyBeforeGate()
        guard policy.isEnabled else { return }
        try openIfNeeded()
        let effectiveNow = try advanceHighWaterMarkForMutation()
        let proof = try createCleanupProof(
            whereClause: "expires_at_ms IS NOT NULL AND expires_at_ms <= ?",
            integerBindings: [effectiveNow]
        )
        defer {
            try? destroyCleanupProof(proof)
            close(proof)
        }
        do {
            try transaction {
                let statement = try prepare("DELETE FROM records WHERE expires_at_ms IS NOT NULL AND expires_at_ms <= ?")
                defer { sqlite3_finalize(statement) }
                try bind(effectiveNow, to: statement, at: 1)
                try stepDone(statement)
            }
            try checkpointAfterDeletion()
            try verifyCleanupProof(proof)
            try destroyCleanupProof(proof)
            cleanupFailureLatched = false
        } catch {
            cleanupFailureLatched = true
            throw error
        }
        generation &+= 1
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        try createProtectedDirectory()
        try acquireAdvisoryLock()
        let existingIdentity = try validateExistingDatabaseFile()
        var handle: OpaquePointer?
        // SQLite opens the database itself, but the surrounding directory and
        // file are verified before and after.  NOFOLLOW is used when the
        // platform SQLite exposes it; this is intentionally fail-closed on
        // platforms where protected local storage cannot be established.
        // Apple ships SQLite builds that declare SQLITE_OPEN_NOFOLLOW but reject
        // it at runtime.  The store therefore establishes its own descriptor
        // based no-follow boundary before asking SQLite to open the verified
        // regular file, and verifies the result again immediately afterwards.
        // NOFOLLOW is a SQLite-level second boundary. The descriptor-relative
        // checks below still remain necessary because SQLite opens sidecars.
        let baseFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let noFollowResult = sqlite3_open_v2(databaseURL.path, &handle, baseFlags | SQLITE_OPEN_NOFOLLOW, nil)
        // Some Apple SQLite builds declare NOFOLLOW but reject it at runtime.
        // In that narrow compatibility case the descriptor-relative, nofollow
        // pre-open validation is repeated immediately before a base open; a
        // symlink/replacement never becomes an accepted store artifact.
        if noFollowResult != SQLITE_OK {
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            _ = try validateExistingDatabaseFile()
            guard sqlite3_open_v2(databaseURL.path, &handle, baseFlags, nil) == SQLITE_OK else {
                if let handle { sqlite3_close_v2(handle) }
                throw HistoryStoreError.ioFailed
            }
        }
        guard let handle else { throw HistoryStoreError.ioFailed }
        database = handle
        do {
            // sqlite3_open_v2 creates a new database with the process umask;
            // narrow it before any schema or transcript can be written.
            _ = chmod(databaseURL.path, 0o600)
            try validateOpenedDatabaseFile(expected: existingIdentity)
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA journal_size_limit = 0")
            try execute("PRAGMA temp_store = MEMORY")
            // This applies before any pre-delivery work and keeps a contended
            // SQLite lock from consuming the release budget. Deadline progress
            // handling adds a second, externally observable interruption path.
            sqlite3_busy_timeout(handle, 20)
            try verifySecureDelete()
            let schemaVersion = try validatedSchemaVersion()
            if schemaVersion == 0 {
                try transaction {
                    try createSchema()
                    if testSchemaCreationFailure { throw HistoryStoreError.migrationFailed }
                    try validateExactSchema()
                }
            } else {
                try validateExactSchema()
            }
            try protectSQLiteArtifacts()
            try verifyProtectedSQLiteArtifacts()
            inMemoryHighWaterMark = try storedHighWaterMark()
            if existingIdentity != nil {
                // A crash can separate a successful SQLite transition from its
                // UserDefaults mirror. The durable store wins on reopen.
                policy = try storedRetentionPolicy()
            } else {
                try persistPolicyAndPurge(policy)
            }
        } catch {
            closeDatabase()
            throw error
        }
    }

    private func reconcilePolicyBeforeGate() throws {
        guard database == nil,
              FileManager.default.fileExists(atPath: directoryURL.path)
        else { return }
        try openIfNeeded()
        policy = try storedRetentionPolicy()
    }

    private func createProtectedDirectory() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        let parentURL = directoryURL.deletingLastPathComponent()
        // Application Support/bundle-id is application-owned but may not yet
        // exist on a fresh install. Create only that parent, then create and
        // open the final history directory relative to a no-follow descriptor.
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let parentDescriptor = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
        defer { close(parentDescriptor) }
        let name = directoryURL.lastPathComponent
        if mkdirat(parentDescriptor, name, 0o700) != 0 && errno != EEXIST {
            throw HistoryStoreError.ioFailed
        }
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
        defer { close(descriptor) }
        try verifyPrivateDirectoryDescriptor(descriptor)
        var directory = directoryURL
        try directory.setResourceValues(values)
        let markerDescriptor = openat(descriptor, ".metadata_never_index", O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
        guard markerDescriptor >= 0 else { throw HistoryStoreError.ioFailed }
        guard fchmod(markerDescriptor, 0o600) == 0 else {
            close(markerDescriptor)
            throw HistoryStoreError.permissionDenied
        }
        try verifyPrivateRegularFileDescriptor(markerDescriptor)
        close(markerDescriptor)
        try verifyDirectory(directoryURL)
    }

    private func verifyPrivateDirectoryDescriptor(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              (status.st_mode & 0o777) == 0o700
        else { throw HistoryStoreError.permissionDenied }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { throw HistoryStoreError.unsupportedFilesystem }
        let filesystemName = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard ["apfs", "hfs", "tmpfs"].contains(filesystemName.lowercased()) else {
            throw HistoryStoreError.unsupportedFilesystem
        }
    }

    private func verifyPrivateRegularFileDescriptor(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & 0o777) == 0o600
        else { throw HistoryStoreError.permissionDenied }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { throw HistoryStoreError.unsupportedFilesystem }
        let filesystemName = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard ["apfs", "hfs", "tmpfs"].contains(filesystemName.lowercased()) else {
            throw HistoryStoreError.unsupportedFilesystem
        }
    }

    private func withHistoryDirectoryDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        let parentURL = directoryURL.deletingLastPathComponent()
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
        defer { close(parent) }
        let directory = openat(parent, directoryURL.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
        defer { close(directory) }
        try verifyPrivateDirectoryDescriptor(directory)
        return try body(directory)
    }

    private func removeOwnedStoreDirectory() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let parentURL = directoryURL.deletingLastPathComponent()
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
        defer { close(parent) }
        let name = directoryURL.lastPathComponent
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
        defer { close(directory) }
        try verifyPrivateDirectoryDescriptor(directory)
        for artifact in [Self.databaseName, "\(Self.databaseName)-wal", "\(Self.databaseName)-shm", ".history.lock", ".metadata_never_index"] {
            if unlinkat(directory, artifact, 0) != 0 && errno != ENOENT {
                throw HistoryStoreError.ioFailed
            }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw HistoryStoreError.ioFailed }
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

    /// A valid application id/version is not enough: a malformed or replaced
    /// database can otherwise smuggle in an unexpected trigger/table that sees
    /// transcript text. Version 1 accepts only its fixed schema objects.
    private func validateExactSchema() throws {
        let statement = try prepare("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        defer { sqlite3_finalize(statement) }
        var found = Set<String>()
        var definitions: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let type = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else {
                throw HistoryStoreError.corrupt
            }
            let typeName = String(cString: type)
            let objectName = String(cString: name)
            found.insert("\(typeName):\(objectName)")
            if let sql = sqlite3_column_text(statement, 2) {
                definitions["\(typeName):\(objectName)"] = normalizedSchemaSQL(String(cString: sql))
            }
        }
        guard sqlite3_errcode(database) == SQLITE_DONE else { throw HistoryStoreError.corrupt }
        let expected: Set<String> = [
            "table:store_metadata", "table:records", "table:records_fts",
            "table:records_fts_data", "table:records_fts_idx",
            "table:records_fts_docsize", "table:records_fts_config",
            "index:records_created_at", "index:records_expiry",
            "trigger:records_ai", "trigger:records_ad",
        ]
        guard found == expected else { throw HistoryStoreError.corrupt }
        let expectedDefinitions: [String: String] = [
            "table:store_metadata": "CREATE TABLE store_metadata ( key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL )",
            "table:records": "CREATE TABLE records ( id TEXT PRIMARY KEY NOT NULL, created_at_ms INTEGER NOT NULL, expires_at_ms INTEGER, text TEXT NOT NULL CHECK(length(text) > 0), delivery_state TEXT NOT NULL CHECK(delivery_state IN ('pending', 'inserted', 'copied_accessibility', 'insertion_failed')), delivery_updated_at_ms INTEGER )",
            "index:records_created_at": "CREATE INDEX records_created_at ON records(created_at_ms DESC, id DESC)",
            "index:records_expiry": "CREATE INDEX records_expiry ON records(expires_at_ms)",
            "table:records_fts": "CREATE VIRTUAL TABLE records_fts USING fts5(text, content='records', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')",
            "trigger:records_ai": "CREATE TRIGGER records_ai AFTER INSERT ON records BEGIN INSERT INTO records_fts(rowid, text) VALUES (new.rowid, new.text); END",
            "trigger:records_ad": "CREATE TRIGGER records_ad AFTER DELETE ON records BEGIN INSERT INTO records_fts(records_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END",
        ].mapValues { normalizedSchemaSQL($0) }
        guard expectedDefinitions.allSatisfy({ definitions[$0.key] == $0.value }) else {
            throw HistoryStoreError.corrupt
        }
        try validateSchemaColumnsAndMetadata()
    }

    private func normalizedSchemaSQL(_ sql: String) -> String {
        sql.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func validateSchemaColumnsAndMetadata() throws {
        let recordsColumns = try tableColumns("records")
        let expectedRecords: [(String, String, Int32, Int32)] = [
            ("id", "TEXT", 1, 1), ("created_at_ms", "INTEGER", 1, 0),
            ("expires_at_ms", "INTEGER", 0, 0), ("text", "TEXT", 1, 0),
            ("delivery_state", "TEXT", 1, 0), ("delivery_updated_at_ms", "INTEGER", 0, 0),
        ]
        guard recordsColumns.elementsEqual(expectedRecords, by: { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }) else {
            throw HistoryStoreError.corrupt
        }
        let metadataColumns = try tableColumns("store_metadata")
        let expectedMetadata: [(String, String, Int32, Int32)] = [("key", "TEXT", 1, 1), ("value", "TEXT", 1, 0)]
        guard metadataColumns.elementsEqual(expectedMetadata, by: { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }) else {
            throw HistoryStoreError.corrupt
        }
        let metadata = try metadataValues()
        guard Set(metadata.keys) == Set(["last_observed_now_ms", "retention_policy"]),
              let highWater = metadata["last_observed_now_ms"], Int64(highWater) != nil,
              let retention = metadata["retention_policy"], HistoryRetentionPolicy(rawValue: retention) != nil
        else { throw HistoryStoreError.corrupt }
        let secureDelete = try prepare("SELECT v FROM records_fts_config WHERE k = 'secure-delete'")
        defer { sqlite3_finalize(secureDelete) }
        guard sqlite3_step(secureDelete) == SQLITE_ROW, sqlite3_column_int(secureDelete, 0) == 1 else {
            throw HistoryStoreError.corrupt
        }
    }

    private func tableColumns(_ table: String) throws -> [(String, String, Int32, Int32)] {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var output: [(String, String, Int32, Int32)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1), let type = sqlite3_column_text(statement, 2) else {
                throw HistoryStoreError.corrupt
            }
            output.append((String(cString: name), String(cString: type), sqlite3_column_int(statement, 3), sqlite3_column_int(statement, 5)))
        }
        guard sqlite3_errcode(database) == SQLITE_DONE else { throw HistoryStoreError.corrupt }
        return output
    }

    private func metadataValues() throws -> [String: String] {
        let statement = try prepare("SELECT key, value FROM store_metadata")
        defer { sqlite3_finalize(statement) }
        var output: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) else {
                throw HistoryStoreError.corrupt
            }
            output[String(cString: key)] = String(cString: value)
        }
        guard sqlite3_errcode(database) == SQLITE_DONE else { throw HistoryStoreError.corrupt }
        return output
    }

    private func persistPolicyAndPurge(_ policy: HistoryRetentionPolicy) throws {
        let effectiveNow = try advanceHighWaterMarkForMutation()
        let proof: Int32
        switch policy {
        case .off, .session:
            proof = try createCleanupProof()
        case .days7, .days30, .days90:
            proof = try createCleanupProof(
                whereClause: """
                    MIN(COALESCE(expires_at_ms, 9223372036854775807), created_at_ms + ?) <= ?
                    """,
                integerBindings: [policy.durationMilliseconds!, effectiveNow]
            )
        case .untilDeleted:
            // No existing expiry is extended and no row is removed.
            proof = try createCleanupProof(whereClause: "0")
        }
        defer {
            try? destroyCleanupProof(proof)
            close(proof)
        }
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
        try verifyCleanupProof(proof)
        try destroyCleanupProof(proof)
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

    private func storedRetentionPolicy() throws -> HistoryRetentionPolicy {
        let statement = try prepare("SELECT value FROM store_metadata WHERE key = 'retention_policy'")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0),
              let policy = HistoryRetentionPolicy(rawValue: String(cString: value))
        else { throw HistoryStoreError.corrupt }
        return policy
    }

    private func metadataSet(_ key: String, _ value: String) throws {
        let statement = try prepare("INSERT INTO store_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        try bind(value, to: statement, at: 2)
        try stepDone(statement)
    }

    private func textForRecord(id: String) throws -> String? {
        let statement = try prepare("SELECT text FROM records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            if sqlite3_errcode(database) == SQLITE_DONE { return nil }
            throw mapSQLiteError(sqlite3_errcode(database))
        }
        guard let value = sqlite3_column_text(statement, 0) else { throw HistoryStoreError.corrupt }
        return String(cString: value)
    }

    /// Streams every transcript into an owner-only proof spool before deletion.
    /// Memory is bounded to one record (100 KB); the spool is itself a
    /// controlled artifact, securely truncated and unlinked before success.
    private func createCleanupProof(
        whereClause: String? = nil,
        integerBindings: [Int64] = []
    ) throws -> Int32 {
        let descriptor = try withHistoryDirectoryDescriptor { directory in
            let fd = openat(directory, ".cleanup-proof", O_CREAT | O_TRUNC | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw HistoryStoreError.ioFailed }
            guard fchmod(fd, 0o600) == 0 else {
                close(fd)
                throw HistoryStoreError.permissionDenied
            }
            try verifyPrivateRegularFileDescriptor(fd)
            return fd
        }
        do {
            let predicate = whereClause.map { " WHERE \($0)" } ?? ""
            let statement = try prepare("SELECT CAST(text AS BLOB) FROM records\(predicate) ORDER BY rowid")
            defer { sqlite3_finalize(statement) }
            for (offset, value) in integerBindings.enumerated() {
                try bind(value, to: statement, at: Int32(offset + 1))
            }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw mapSQLiteError(result) }
                let byteCount = Int(sqlite3_column_bytes(statement, 0))
                guard byteCount > 0, byteCount <= Self.maximumFinalTextBytes,
                      let pointer = sqlite3_column_blob(statement, 0)
                else { throw HistoryStoreError.corrupt }
                var length = UInt32(byteCount).littleEndian
                try withUnsafeBytes(of: &length) { try writeAll($0, to: descriptor) }
                try writeAll(UnsafeRawBufferPointer(start: pointer, count: byteCount), to: descriptor)
            }
            guard fsync(descriptor) == 0 else {
                throw HistoryStoreError.ioFailed
            }
            return descriptor
        } catch {
            close(descriptor)
            try? withHistoryDirectoryDescriptor { _ = unlinkat($0, ".cleanup-proof", 0) }
            throw error
        }
    }

    private func verifyCleanupProof(_ proof: Int32) throws {
        if testProofFailure { throw HistoryStoreError.cleanupIncomplete }
        guard lseek(proof, 0, SEEK_SET) >= 0 else { throw HistoryStoreError.cleanupIncomplete }
        while true {
            // Bound memory while avoiding one full artifact scan per row.
            // Every row is still covered; only the batch size is capped.
            var sentinels: [Data] = []
            sentinels.reserveCapacity(64)
            for _ in 0..<64 {
                guard let lengthBytes = try readExact(4, from: proof) else { break }
                let length = lengthBytes.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
                }
                guard length > 0, length <= Self.maximumFinalTextBytes,
                      let sentinel = try readExact(Int(length), from: proof)
                else { throw HistoryStoreError.cleanupIncomplete }
                sentinels.append(sentinel)
            }
            if sentinels.isEmpty { break }
            try withHistoryDirectoryDescriptor { directory in
                try verifyNoUnexpectedArtifacts(directory)
                for name in Self.controlledArtifactNames where name != ".cleanup-proof" {
                    let artifact = openat(directory, name, O_RDONLY | O_NOFOLLOW)
                    if artifact < 0 {
                        guard errno == ENOENT else { throw HistoryStoreError.cleanupIncomplete }
                        continue
                    }
                    defer { close(artifact) }
                    try verifyPrivateRegularFileDescriptor(artifact)
                    if try artifactContainsAnySentinel(artifact, sentinels: sentinels) {
                        throw HistoryStoreError.cleanupIncomplete
                    }
                }
            }
        }
    }

    private func destroyCleanupProof(_ descriptor: Int32) throws {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw HistoryStoreError.cleanupIncomplete }
        let zeros = [UInt8](repeating: 0, count: 16_384)
        var remaining = lseek(descriptor, 0, SEEK_END)
        guard remaining >= 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw HistoryStoreError.cleanupIncomplete
        }
        while remaining > 0 {
            let count = min(Int(remaining), zeros.count)
            try zeros.withUnsafeBytes { try writeAll(UnsafeRawBufferPointer(rebasing: $0.prefix(count)), to: descriptor) }
            remaining -= off_t(count)
        }
        guard fsync(descriptor) == 0, ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else {
            throw HistoryStoreError.cleanupIncomplete
        }
        try withHistoryDirectoryDescriptor { directory in
            if unlinkat(directory, ".cleanup-proof", 0) != 0 && errno != ENOENT {
                throw HistoryStoreError.cleanupIncomplete
            }
        }
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let result = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw HistoryStoreError.ioFailed }
            offset += result
        }
    }

    private func readExact(_ count: Int, from descriptor: Int32) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let result = data.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            if result < 0, errno == EINTR { continue }
            if result == 0 {
                if offset == 0 { return nil }
                throw HistoryStoreError.cleanupIncomplete
            }
            guard result > 0 else { throw HistoryStoreError.ioFailed }
            offset += result
        }
        return data
    }

    /// Successful deletion is only reported after SQLite's truncating
    /// checkpoint and a descriptor-relative scan of every store artifact.  It
    /// is not a forensic-erasure promise: if SQLite leaves a matching byte
    /// sequence behind, the operation is reported as incomplete.
    private func verifyRemovedTextIsAbsent(_ values: [String]) throws {
        let sentinels = values.filter { !$0.isEmpty }.map { Data($0.utf8) }
        guard !sentinels.isEmpty else { return }
        try withHistoryDirectoryDescriptor { descriptor in
            try verifyNoUnexpectedArtifacts(descriptor)
            for name in Self.controlledArtifactNames {
                let artifact = openat(descriptor, name, O_RDONLY | O_NOFOLLOW)
                if artifact < 0 {
                    guard errno == ENOENT else { throw HistoryStoreError.ioFailed }
                    continue
                }
                defer { close(artifact) }
                try verifyPrivateRegularFileDescriptor(artifact)
                if try artifactContainsAnySentinel(artifact, sentinels: sentinels) {
                    throw HistoryStoreError.cleanupIncomplete
                }
            }
        }
    }

    private func artifactContainsAnySentinel(_ descriptor: Int32, sentinels: [Data]) throws -> Bool {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw HistoryStoreError.ioFailed }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let tailLimit = max(0, (sentinels.map(\.count).max() ?? 1) - 1)
        var tail = Data()
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return false }
            guard count > 0 else { throw HistoryStoreError.ioFailed }
            var chunk = tail
            chunk.append(buffer, count: Int(count))
            if sentinels.contains(where: { chunk.range(of: $0) != nil }) { return true }
            tail = tailLimit == 0 ? Data() : Data(chunk.suffix(tailLimit))
        }
    }

    private func checkpointAfterDeletion() throws {
        if testCheckpointFailure { throw HistoryStoreError.cleanupIncomplete }
        let statement = try prepare("PRAGMA wal_checkpoint(TRUNCATE)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw mapSQLiteError(sqlite3_errcode(database)) }
        // SQLite reports (busy, log frames, checkpointed frames).  A busy result
        // means plaintext may remain in the WAL; surface an honest incomplete
        // cleanup state instead of claiming Clear/Off completed.
        guard sqlite3_column_int(statement, 0) == 0,
              sqlite3_column_int(statement, 1) == 0,
              sqlite3_column_int(statement, 2) == 0
        else { throw HistoryStoreError.cleanupIncomplete }
    }

    private func verifySecureDelete() throws {
        let statement = try prepare("PRAGMA secure_delete")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else {
            throw HistoryStoreError.permissionDenied
        }
    }

    private func transaction<T>(
        _ deadlineUptimeNanoseconds: UInt64? = nil,
        cancellation: HistoryWriteCancellation? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try requireBeforeDeadline(deadlineUptimeNanoseconds, cancellation: cancellation)
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try requireBeforeDeadline(deadlineUptimeNanoseconds, cancellation: cancellation)
            try execute("COMMIT")
            cancellation?.acknowledge(.committed)
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            cancellation?.acknowledge(.rolledBack)
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
    static func ftsQuery(_ tokens: [String]) -> String {
        tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
    }

    /// Mirrors the unicode61 notion of a word closely enough to avoid exposing
    /// any punctuation or FTS operators as grammar. The FTS layer remains the
    /// authority for case/diacritic folding and matching.
    static func literalTokens(_ query: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let parts = query.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        var seen = Set<String>()
        let stableLocale = Locale(identifier: "en_US_POSIX")
        return parts.filter {
            seen.insert($0.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: stableLocale
            )).inserted
        }
    }

    private func requireBeforeDeadline(_ deadline: UInt64?, cancellation: HistoryWriteCancellation? = nil) throws {
        if cancellation?.isInterrupted == true { throw HistoryStoreError.deadlineExceeded }
        guard let deadline else { return }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            cancellation?.interrupt()
            throw HistoryStoreError.deadlineExceeded
        }
    }

    private func installDeadlineProgressHandler(_ writeCancellation: HistoryWriteCancellation) {
        guard let database else { return }
        sqlite3_progress_handler(database, 100, { context in
            let cancellation = Unmanaged<HistoryWriteCancellation>.fromOpaque(context!).takeUnretainedValue()
            return cancellation.shouldInterrupt ? 1 : 0
        }, Unmanaged.passUnretained(writeCancellation).toOpaque())
    }

    private func verifyDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw HistoryStoreError.unsupportedFilesystem }
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        guard mode.map({ ($0 & 0o077) == 0 }) == true else { throw HistoryStoreError.permissionDenied }
    }

    private func validateExistingDatabaseFile() throws -> FileIdentity? {
        try withHistoryDirectoryDescriptor { directory in
            let descriptor = openat(directory, Self.databaseName, O_RDONLY | O_NOFOLLOW)
            if descriptor < 0 {
                guard errno == ENOENT else { throw HistoryStoreError.unsupportedFilesystem }
                return nil
            }
            defer { close(descriptor) }
            try verifyPrivateRegularFileDescriptor(descriptor)
            return try fileIdentity(descriptor)
        }
    }

    private func validateOpenedDatabaseFile(expected: FileIdentity?) throws {
        guard let database,
              let filename = sqlite3_db_filename(database, "main"),
              URL(fileURLWithPath: String(cString: filename)).standardizedFileURL == databaseURL.standardizedFileURL
        else { throw HistoryStoreError.unsupportedFilesystem }
        var sqliteFile: UnsafeMutableRawPointer?
        guard sqlite3_file_control(database, "main", SQLITE_FCNTL_FILE_POINTER, &sqliteFile) == SQLITE_OK,
              sqliteFile != nil
        else { throw HistoryStoreError.unsupportedFilesystem }
        let identity = try withHistoryDirectoryDescriptor { directory in
            let descriptor = openat(directory, Self.databaseName, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
            defer { close(descriptor) }
            try verifyPrivateRegularFileDescriptor(descriptor)
            return try fileIdentity(descriptor)
        }
        if let expected, expected != identity { throw HistoryStoreError.unsupportedFilesystem }
    }

    private func fileIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw HistoryStoreError.ioFailed }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func acquireAdvisoryLock() throws {
        guard lockFileDescriptor < 0 else { return }
        let descriptor = try withHistoryDirectoryDescriptor { directory in
            let descriptor = openat(directory, ".history.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw HistoryStoreError.unsupportedFilesystem }
            guard fchmod(descriptor, 0o600) == 0 else {
                close(descriptor)
                throw HistoryStoreError.permissionDenied
            }
            try verifyPrivateRegularFileDescriptor(descriptor)
            return descriptor
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw HistoryStoreError.busy
        }
        lockFileDescriptor = descriptor
    }

    private func validatedSchemaVersion() throws -> Int32 {
        let applicationID = try pragmaInt("application_id")
        guard applicationID == 0 || applicationID == 1_396_788_296 else { throw HistoryStoreError.corrupt }
        let version = try pragmaInt("user_version")
        guard version == 0 || version == 1 else { throw HistoryStoreError.migrationFailed }
        return version
    }

    private func pragmaInt(_ name: String) throws -> Int32 {
        let statement = try prepare("PRAGMA \(name)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw mapSQLiteError(sqlite3_errcode(database)) }
        return sqlite3_column_int(statement, 0)
    }

    private func verifyProtectedSQLiteArtifacts() throws {
        try withHistoryDirectoryDescriptor { directory in
            try verifyNoUnexpectedArtifacts(directory)
            for name in Self.controlledArtifactNames {
                let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
                if descriptor < 0 {
                    guard errno == ENOENT else { throw HistoryStoreError.unsupportedFilesystem }
                    continue
                }
                defer { close(descriptor) }
                try verifyPrivateRegularFileDescriptor(descriptor)
                if name == ".cleanup-proof" || name == ".migration-temp" {
                    throw HistoryStoreError.cleanupIncomplete
                }
            }
        }
    }

    private func protectSQLiteArtifacts() throws {
        try withHistoryDirectoryDescriptor { directory in
            for name in Self.controlledArtifactNames {
                let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
                if descriptor < 0 {
                    guard errno == ENOENT else { throw HistoryStoreError.ioFailed }
                    continue
                }
                defer { close(descriptor) }
                guard fchmod(descriptor, 0o600) == 0 else { throw HistoryStoreError.permissionDenied }
                try verifyPrivateRegularFileDescriptor(descriptor)
            }
        }
    }

    /// Enumerate through the already verified directory descriptor.  This is
    /// intentionally streaming: a hostile or corrupt directory must not make
    /// the process materialize arbitrary entries before it can fail closed.
    private func verifyNoUnexpectedArtifacts(_ directory: Int32) throws {
        let streamDescriptor = dup(directory)
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { close(streamDescriptor) }
            throw HistoryStoreError.ioFailed
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard Self.controlledArtifactNames.contains(name) else {
                throw HistoryStoreError.corrupt
            }
        }
    }
}

/// A per-operation lock-protected bridge between a delivery deadline and SQLite's
/// synchronous C API.  Actor isolation cannot service a cancellation message
/// while SQLite is executing, so the deadline task calls `sqlite3_interrupt`
/// through this object directly.  A token is created before a write is queued;
/// until its own operation attaches a SQLite handle, interrupting it is a no-op
/// for every other writer.  The actor still owns the transaction and records
/// its final rollback/commit acknowledgement before returning.
public final class HistoryWriteCancellation: @unchecked Sendable {
    enum Acknowledgement: Equatable { case none, committed, rolledBack }

    private let lock = NSLock()
    private var database: OpaquePointer?
    private var deadline: UInt64?
    private var interrupted = false
    private var acknowledgement: Acknowledgement = .none

    public init() {}

    var isInterrupted: Bool { lock.withLock { interrupted } }
    var shouldInterrupt: Bool {
        lock.withLock {
            if interrupted { return true }
            guard let deadline else { return false }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                interrupted = true
                return true
            }
            return false
        }
    }

    func begin(_ deadline: UInt64?) {
        lock.withLock {
            self.deadline = deadline
            // A deadline task can cancel while this operation is still queued
            // behind another actor turn. Preserve that signal so the queued
            // request exits before it ever attaches SQLite.
            acknowledgement = .none
        }
    }

    func attach(_ database: OpaquePointer) {
        lock.withLock {
            self.database = database
            if interrupted || (deadline.map { DispatchTime.now().uptimeNanoseconds >= $0 } ?? false) {
                interrupted = true
                // Keep the lease lock held across the C call. `finish()` and
                // actor-owned connection close must acquire this same lock,
                // so the handle cannot be detached/reused while interrupt is
                // dereferencing it.
                sqlite3_interrupt(database)
            }
        }
    }

    public func interrupt() {
        lock.withLock {
            interrupted = true
            if let database { sqlite3_interrupt(database) }
        }
    }

    func acknowledge(_ acknowledgement: Acknowledgement) {
        lock.withLock { self.acknowledgement = acknowledgement }
    }

    func finish() {
        lock.withLock {
            database = nil
            deadline = nil
            // An interrupted write must have reached the rollback path before
            // this method is called.  Leave a failed acknowledgement visible
            // to debugging/tests instead of silently resetting it.
            if interrupted && acknowledgement == .none { acknowledgement = .rolledBack }
            interrupted = false
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
