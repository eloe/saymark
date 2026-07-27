import Foundation
import Darwin
import SQLite3
import XCTest
@testable import SaymarkKit

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var now: Int64!

    override func setUpWithError() throws {
        if let subprocessDirectory = ProcessInfo.processInfo.environment["SAYMARK_HISTORY_CRASH_DIRECTORY"] {
            directory = URL(fileURLWithPath: subprocessDirectory, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("saymark-history-\(UUID().uuidString)", isDirectory: true)
        }
        now = 1_700_000_000_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOffNeverCreatesStoreOrRecordsText() async throws {
        let store = try SQLiteHistoryStore(directoryURL: directory, policy: .off, now: { self.now })

        let record = try await store.recordFinal(.init(text: "must not persist"))

        XCTAssertNil(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFinalCreatesPendingExactTextAndUpdatesOnce() async throws {
        let store = try makeStore()
        let inserted = try await store.recordFinal(.init(text: "exact final text"))
        let record = try XCTUnwrap(inserted)

        XCTAssertEqual(record.text, "exact final text")
        XCTAssertEqual(record.deliveryState, .pending)
        let insertedState = try await store.updateDeliveryState(id: record.id, to: .inserted)
        let rejectedState = try await store.updateDeliveryState(id: record.id, to: .insertionFailed)
        let records = try await store.records()
        XCTAssertTrue(insertedState)
        XCTAssertFalse(rejectedState)
        XCTAssertEqual(records.first?.deliveryState, .inserted)
    }

    func testSecureInputAndHUDOnlyAreNeverStored() async throws {
        let store = try makeStore()

        let credential = try await store.recordFinal(.init(text: "credential", secureInputActive: true))
        let hud = try await store.recordFinal(.init(text: "hud", isHUDOnly: true))
        let records = try await store.records()
        XCTAssertNil(credential)
        XCTAssertNil(hud)
        XCTAssertTrue(records.isEmpty)
    }

    func testSearchUsesLiteralPrefixTokensWithAndAndResultCap() async throws {
        let store = try makeStore()
        _ = try await store.recordFinal(.init(text: "café crème"))
        now += 1
        _ = try await store.recordFinal(.init(text: "creamy cafe"))
        now += 1
        _ = try await store.recordFinal(.init(text: "AND OR NOT are text"))
        for index in 0..<30 {
            now += 1
            _ = try await store.recordFinal(.init(text: "common \(index)"))
        }

        let cafeResults = try await store.records(query: "cafe cre")
        let operators = try await store.records(query: "AND OR")
        let common = try await store.records(query: "common", limit: 99)
        XCTAssertEqual(cafeResults.count, 2)
        XCTAssertEqual(operators.count, 1)
        XCTAssertEqual(common.count, 25)
    }

    func testUnicodeSearchContractCoversNormalizationScriptsAndLiteralGrammar() async throws {
        let store = try makeStore()
        let fixtures = [
            "café crème",
            "cafe\u{301} combine",
            "Straße berlin",
            "İstanbul Türkiye",
            "مرحبا بالعالم",
            "AND OR NOT \"quoted\" star* caret^ dash-",
            "private\u{E000}use unicode category Co",
        ]
        for fixture in fixtures {
            _ = try await store.recordFinal(.init(text: fixture))
            now += 1
        }

        let cafe = try await store.records(query: "cafe café")
        let german = try await store.records(query: "straße ber")
        let turkish = try await store.records(query: "istanbul tür")
        let rtl = try await store.records(query: "مرحبا بالع")
        let boolean = try await store.records(query: "AND OR NOT")
        let grammar = try await store.records(query: "\"quoted\" star* caret^ dash-")
        let emojiOnly = try await store.records(query: "🧪✨")
        let privateUse = try await store.records(query: "private\u{E000}use")
        XCTAssertEqual(cafe.count, 2)
        XCTAssertEqual(german.count, 1)
        XCTAssertEqual(turkish.count, 1)
        XCTAssertEqual(rtl.count, 1)
        XCTAssertEqual(boolean.count, 1)
        XCTAssertEqual(grammar.count, 1)
        XCTAssertTrue(emojiOnly.isEmpty)
        XCTAssertEqual(privateUse.count, 1)

        let repairedMalformed = String(decoding: [0x66, 0x80, 0x6f], as: UTF8.self)
        _ = try await store.recordFinal(.init(text: repairedMalformed))
        let malformedResults = try await store.records(query: repairedMalformed)
        XCTAssertEqual(malformedResults.count, 1)
    }

    func testTenThousandGeneratedUnicodeQueriesUseRealSQLiteUnicode61WithoutCrash() async throws {
        let store = try makeStore()
        _ = try await store.recordFinal(.init(
            text: "café Straße İ مرحبا עברית AND quoted token42 private\u{E000}use"
        ))
        let metacharacters = [
            "\"", "'", "*", "^", "-", ":", "(", ")", "{", "}", "[", "]",
            "AND", "OR", "NOT", "NEAR", "café", "cafe\u{301}", "ß", "İ",
            "مرحبا", "עברית", "🧪", "\u{E000}", "\n", ";DROP TABLE records;--",
        ]
        for index in 0..<10_000 {
            let query = [
                metacharacters[index % metacharacters.count],
                metacharacters[(index * 7 + 3) % metacharacters.count],
                "token\(index % 97)",
            ].joined(separator: " ")
            let results = try await store.records(query: query)
            XCTAssertLessThanOrEqual(results.count, SQLiteHistoryStore.maximumResultLimit)
        }
    }

    func testShorterRetentionPurgesAndIncreasingDoesNotExtendExistingRows() async throws {
        let store = try makeStore(policy: .untilDeleted)
        let inserted = try await store.recordFinal(.init(text: "bounded"))
        let record = try XCTUnwrap(inserted)

        try await store.setRetentionPolicy(.days7)
        let initialRecords = try await store.records()
        let sevenDayExpiry = try XCTUnwrap(initialRecords.first?.expiresAtMilliseconds)
        try await store.setRetentionPolicy(.days90)
        let increasedRecords = try await store.records()
        XCTAssertEqual(increasedRecords.first?.expiresAtMilliseconds, sevenDayExpiry)

        now += HistoryRetentionPolicy.days7.durationMilliseconds! + 1
        try await store.purgeExpired()
        let expiredRecords = try await store.records()
        XCTAssertTrue(expiredRecords.isEmpty)
        XCTAssertNotNil(record.id)
    }

    func testDeleteAndClearRemoveSearchableRows() async throws {
        let store = try makeStore()
        let inserted = try await store.recordFinal(.init(text: "remove alpha sentinel-A1"))
        let first = try XCTUnwrap(inserted)
        _ = try await store.recordFinal(.init(text: "remove beta sentinel-B2"))

        let deleted = try await store.delete(id: first.id)
        let alpha = try await store.records(query: "alpha")
        XCTAssertTrue(deleted)
        XCTAssertTrue(alpha.isEmpty)
        try await store.clear()
        let all = try await store.records()
        let beta = try await store.records(query: "beta")
        XCTAssertTrue(all.isEmpty)
        XCTAssertTrue(beta.isEmpty)
    }

    func testClearStreamsProofForMoreThanSixtyFourRows() async throws {
        let store = try makeStore()
        for index in 0..<80 {
            _ = try await store.recordFinal(.init(text: "proof-sentinel-\(index)-\(UUID().uuidString)"))
        }

        try await store.clear()

        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".cleanup-proof").path
        ))
    }

    func testExistingDurablePolicyOverridesConflictingBootstrapHint() async throws {
        var original: SQLiteHistoryStore? = try makeStore(policy: .days7)
        try await original?.warmUp()
        let originalPolicy = try await original?.durableRetentionPolicy()
        XCTAssertEqual(originalPolicy, .days7)
        await original?.shutdown()
        original = nil

        let reopened = try SQLiteHistoryStore(
            directoryURL: directory,
            policy: .untilDeleted,
            now: { self.now }
        )
        let reopenedPolicy = try await reopened.durableRetentionPolicy()
        XCTAssertEqual(reopenedPolicy, .days7)
    }

    func testCheckpointFailureReconcilesFromCommittedOffMetadataAndFailsClosed() async throws {
        var original: SQLiteHistoryStore? = try makeStore()
        _ = try await original?.recordFinal(.init(text: "off-checkpoint-private-sentinel"))
        await original?.shutdown()
        original = nil

        let failing = try SQLiteHistoryStore(
            directoryURL: directory,
            policy: .days30,
            now: { self.now },
            testCheckpointFailure: true
        )
        await XCTAssertThrowsErrorAsync(try await failing.setRetentionPolicy(.off)) { error in
            XCTAssertEqual(
                error as? HistoryCommittedCleanupFailure,
                HistoryCommittedCleanupFailure(cause: .cleanupIncomplete)
            )
        }
        let failingPolicy = try await failing.durableRetentionPolicy()
        let blockedRecord = try await failing.recordFinal(.init(text: "must remain blocked"))
        XCTAssertEqual(failingPolicy, .off)
        XCTAssertNil(blockedRecord)
        await failing.shutdown()

        let recovered = try SQLiteHistoryStore(directoryURL: directory, policy: .days30, now: { self.now })
        let recoveredPolicy = try await recovered.durableRetentionPolicy()
        XCTAssertEqual(recoveredPolicy, .off)
        try await recovered.setRetentionPolicy(.off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testProofFailureAfterDownwardCommitUsesDurablePolicyAndBlocksRowsUntilRecovery() async throws {
        var original: SQLiteHistoryStore? = try makeStore(policy: .untilDeleted)
        _ = try await original?.recordFinal(.init(text: "downward-private-sentinel"))
        await original?.shutdown()
        original = nil
        now += HistoryRetentionPolicy.days7.durationMilliseconds! + 1

        let failing = try SQLiteHistoryStore(
            directoryURL: directory,
            policy: .untilDeleted,
            now: { self.now },
            testProofFailure: true
        )
        await XCTAssertThrowsErrorAsync(try await failing.setRetentionPolicy(.days7)) { error in
            XCTAssertEqual(
                error as? HistoryCommittedCleanupFailure,
                HistoryCommittedCleanupFailure(cause: .cleanupIncomplete)
            )
        }
        let failingPolicy = try await failing.durableRetentionPolicy()
        XCTAssertEqual(failingPolicy, .days7)
        await XCTAssertThrowsErrorAsync(try await failing.records()) { error in
            XCTAssertEqual(error as? HistoryStoreError, .cleanupIncomplete)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".cleanup-proof").path
        ))
        await failing.shutdown()

        let recovered = try SQLiteHistoryStore(directoryURL: directory, policy: .untilDeleted, now: { self.now })
        let recoveredPolicy = try await recovered.durableRetentionPolicy()
        XCTAssertEqual(recoveredPolicy, .days7)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".cleanup-proof").path
        ))
        try await recovered.purgeExpired()
        let recoveredRecords = try await recovered.records()
        XCTAssertTrue(recoveredRecords.isEmpty)
    }

    func testPendingProofFromPreActivationCrashIsScrubbedWithoutDeletingRows() async throws {
        var store: SQLiteHistoryStore? = try makeStore()
        _ = try await store?.recordFinal(.init(text: "row survives pending proof"))
        await store?.shutdown()
        store = nil
        let pending = directory.appendingPathComponent(".cleanup-proof.pending")
        try Data("incomplete-private-proof".utf8).write(to: pending)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)

        let reopened = try makeStore()
        let records = try await reopened.records()

        XCTAssertEqual(records.map(\.text), ["row survives pending proof"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertFalse(try controlledArtifactsContain(Data("incomplete-private-proof".utf8)))
    }

    func testInvalidActivatedProofFailsClosedAndIsNotSilentlyDiscarded() async throws {
        var store: SQLiteHistoryStore? = try makeStore()
        _ = try await store?.recordFinal(.init(text: "must remain fail closed"))
        await store?.shutdown()
        store = nil
        let proof = directory.appendingPathComponent(".cleanup-proof")
        try Data("invalid-activated-proof".utf8).write(to: proof)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proof.path)

        let reopened = try makeStore()
        await XCTAssertThrowsErrorAsync(try await reopened.records()) { error in
            XCTAssertEqual(error as? HistoryStoreError, .cleanupIncomplete)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: proof.path))
    }

    func testSubprocessSIGKILLReleasesLockAndResumesCommittedWALCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["SAYMARK_HISTORY_CRASH_CHILD"] == "1" {
            var setup: SQLiteHistoryStore? = try SQLiteHistoryStore(
                directoryURL: directory,
                policy: .days30,
                now: { self.now }
            )
            _ = try await setup?.recordFinal(.init(
                text: environment["SAYMARK_HISTORY_CRASH_SENTINEL"]!
            ))
            await setup?.shutdown()
            setup = nil
            let store = try SQLiteHistoryStore(
                directoryURL: directory,
                policy: .days30,
                now: { self.now },
                testProofFailure: true
            )
            do {
                try await store.clear()
                XCTFail("Injected proof failure unexpectedly succeeded")
            } catch {
                guard error as? HistoryCommittedCleanupFailure
                    == HistoryCommittedCleanupFailure(cause: .cleanupIncomplete)
                else { throw error }
            }
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".cleanup-proof").path
            ))
            kill(getpid(), SIGKILL)
            return
        }

        let sentinel = "subprocesscrashprivacytoken\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
        )
        process.arguments = [
            "-XCTest",
            "HistoryStoreTests/testSubprocessSIGKILLReleasesLockAndResumesCommittedWALCleanup",
            Bundle(for: type(of: self)).bundleURL.path,
        ]
        var childEnvironment = environment
        childEnvironment["SAYMARK_HISTORY_CRASH_CHILD"] = "1"
        childEnvironment["SAYMARK_HISTORY_CRASH_DIRECTORY"] = directory.path
        childEnvironment["SAYMARK_HISTORY_CRASH_SENTINEL"] = sentinel
        process.environment = childEnvironment
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let childOutput = String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile()
                + standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertEqual(process.terminationReason, .uncaughtSignal, childOutput)
        XCTAssertEqual(process.terminationStatus, SIGKILL, childOutput)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".cleanup-proof").path
        ))

        let recovered = try makeStore()
        let rows = try await recovered.records()
        XCTAssertTrue(rows.isEmpty)
        await recovered.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".cleanup-proof").path
        ))
        XCTAssertFalse(try controlledArtifactsContain(Data(sentinel.lowercased().utf8)))
    }

    func testEveryDestructivePathRemovesFullAndFTSNormalizedTokenFragments() async throws {
        enum DestructivePath: CaseIterable { case delete, clear, off, session, purge, downward }
        let root = directory!
        for (index, path) in DestructivePath.allCases.enumerated() {
            directory = root.appendingPathComponent("path-\(index)", isDirectory: true)
            now = 1_700_000_000_000
            let normalizedToken = "privacytoken\(index)abcdefghijklmnopqrstuv"
            let fullText = "Café \(normalizedToken.uppercased())"
            let initialPolicy: HistoryRetentionPolicy = path == .downward ? .untilDeleted : .days7
            let store = try makeStore(policy: initialPolicy)
            let inserted = try await store.recordFinal(.init(text: fullText))
            let record = try XCTUnwrap(inserted)
            XCTAssertTrue(try controlledArtifactsContain(Data(normalizedToken.utf8)))

            switch path {
            case .delete:
                let deleted = try await store.delete(id: record.id)
                XCTAssertTrue(deleted)
            case .clear:
                try await store.clear()
            case .off:
                try await store.setRetentionPolicy(.off)
            case .session:
                try await store.setRetentionPolicy(.session)
            case .purge:
                now += HistoryRetentionPolicy.days7.durationMilliseconds! + 1
                try await store.purgeExpired()
            case .downward:
                now += HistoryRetentionPolicy.days7.durationMilliseconds! + 1
                try await store.setRetentionPolicy(.days7)
            }

            await store.shutdown()
            for probe in [
                Data(fullText.utf8),
                Data(normalizedToken.utf8),
                Data(normalizedToken.prefix(12).utf8),
                Data(normalizedToken.suffix(12).utf8),
            ] {
                XCTAssertFalse(try controlledArtifactsContain(probe), "\(path) retained \(String(decoding: probe, as: UTF8.self))")
            }
        }
        directory = root
    }

    func testDeleteAllowsDuplicateTextAndSharedTokensStillOwnedByRetainedRows() async throws {
        let store = try makeStore()
        let shared = "sharedprivacytokenabcdefghijklmnopqrstuv"
        let duplicateText = "duplicate exact \(shared)"
        let firstValue = try await store.recordFinal(.init(text: duplicateText))
        let secondValue = try await store.recordFinal(.init(text: duplicateText))
        let distinctValue = try await store.recordFinal(.init(text: "different owner \(shared)"))
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        let distinct = try XCTUnwrap(distinctValue)

        let deletedFirst = try await store.delete(id: first.id)
        XCTAssertTrue(deletedFirst)
        var rows = try await store.records(query: shared)
        XCTAssertEqual(Set(rows.map(\.id)), Set([second.id, distinct.id]))
        let deletedSecond = try await store.delete(id: second.id)
        XCTAssertTrue(deletedSecond)
        rows = try await store.records(query: shared)
        XCTAssertEqual(rows.map(\.id), [distinct.id])
        let deletedDistinct = try await store.delete(id: distinct.id)
        XCTAssertTrue(deletedDistinct)
        let finalRows = try await store.records()
        XCTAssertTrue(finalRows.isEmpty)
    }

    func testPostCommitCleanupFailurePreservesEveryUnderlyingCause() async throws {
        let root = directory!
        for cause in [
            HistoryStoreError.busy,
            .ioFailed,
            .corrupt,
            .permissionDenied,
        ] {
            directory = root.appendingPathComponent("\(cause)", isDirectory: true)
            var setup: SQLiteHistoryStore? = try makeStore()
            _ = try await setup?.recordFinal(.init(text: "post commit \(cause)"))
            await setup?.shutdown()
            setup = nil

            let failing = try SQLiteHistoryStore(
                directoryURL: directory,
                policy: .days30,
                now: { self.now },
                testPostCommitCleanupFailure: cause
            )
            await XCTAssertThrowsErrorAsync(try await failing.clear()) { error in
                XCTAssertEqual(
                    error as? HistoryCommittedCleanupFailure,
                    HistoryCommittedCleanupFailure(cause: cause)
                )
            }
            await failing.shutdown()
        }
        directory = root
    }

    func testSubprocessProofDisposalRecoversFromKillAtEveryTerminalBoundary() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let boundary = environment["SAYMARK_HISTORY_DISPOSAL_CRASH_BOUNDARY"] {
            var setup: SQLiteHistoryStore? = try makeStore()
            _ = try await setup?.recordFinal(.init(
                text: environment["SAYMARK_HISTORY_CRASH_SENTINEL"]!
            ))
            await setup?.shutdown()
            setup = nil
            let store = try SQLiteHistoryStore(
                directoryURL: directory,
                policy: .days30,
                now: { self.now },
                testProofDisposalBoundary: { reached in
                    if reached == boundary { kill(getpid(), SIGKILL) }
                }
            )
            try await store.clear()
            XCTFail("Child did not stop at proof disposal boundary \(boundary)")
            return
        }

        let root = directory!
        for boundary in ["renamed_disposable", "scrubbed", "truncated", "unlinked"] {
            directory = root.appendingPathComponent(boundary, isDirectory: true)
            let sentinel = "disposalcrashprivacytoken\(boundary)abcdefghijkl"
            let result = try runCrashSubprocess(
                test: "HistoryStoreTests/testSubprocessProofDisposalRecoversFromKillAtEveryTerminalBoundary",
                environment: [
                    "SAYMARK_HISTORY_DISPOSAL_CRASH_BOUNDARY": boundary,
                    "SAYMARK_HISTORY_CRASH_DIRECTORY": directory.path,
                    "SAYMARK_HISTORY_CRASH_SENTINEL": sentinel,
                ]
            )
            XCTAssertEqual(result.reason, .uncaughtSignal, result.output)
            XCTAssertEqual(result.status, SIGKILL, result.output)

            let recovered = try makeStore()
            let recoveredRows = try await recovered.records()
            XCTAssertTrue(recoveredRows.isEmpty)
            await recovered.shutdown()
            XCTAssertFalse(try controlledArtifactsContain(Data(sentinel.utf8)))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".cleanup-proof.disposable").path
            ))
        }
        directory = root
    }

    func testSubprocessKillAfterCommitBeforeCheckpointRecoversLiveWAL() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["SAYMARK_HISTORY_LIVE_WAL_CHILD"] == "1" {
            var setup: SQLiteHistoryStore? = try makeStore()
            _ = try await setup?.recordFinal(.init(
                text: environment["SAYMARK_HISTORY_CRASH_SENTINEL"]!
            ))
            await setup?.shutdown()
            setup = nil
            let store = try SQLiteHistoryStore(
                directoryURL: directory,
                policy: .days30,
                now: { self.now },
                testBeforeDeletionCheckpoint: { kill(getpid(), SIGKILL) }
            )
            try await store.clear()
            XCTFail("Child reached past the pre-checkpoint kill boundary")
            return
        }

        let sentinel = "livewalprivacytoken\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let result = try runCrashSubprocess(
            test: "HistoryStoreTests/testSubprocessKillAfterCommitBeforeCheckpointRecoversLiveWAL",
            environment: [
                "SAYMARK_HISTORY_LIVE_WAL_CHILD": "1",
                "SAYMARK_HISTORY_CRASH_DIRECTORY": directory.path,
                "SAYMARK_HISTORY_CRASH_SENTINEL": sentinel,
            ]
        )
        XCTAssertEqual(result.reason, .uncaughtSignal, result.output)
        XCTAssertEqual(result.status, SIGKILL, result.output)
        let wal = directory.appendingPathComponent("\(SQLiteHistoryStore.databaseName)-wal")
        let walSize = try wal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(walSize, 32, "child did not leave committed WAL frames")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".cleanup-proof").path
        ))

        let recovered = try makeStore()
        let recoveredRows = try await recovered.records()
        XCTAssertTrue(recoveredRows.isEmpty)
        await recovered.shutdown()
        XCTAssertFalse(try controlledArtifactsContain(Data(sentinel.utf8)))
    }

    func testPurgeAndSessionTransitionsByteScanEveryControlledArtifact() async throws {
        let purgeSentinel = "purge-byte-sentinel-\(UUID().uuidString)"
        var store: SQLiteHistoryStore? = try makeStore(policy: .days7)
        _ = try await store?.recordFinal(.init(text: purgeSentinel))
        now += HistoryRetentionPolicy.days7.durationMilliseconds! + 1
        try await store?.purgeExpired()
        await store?.shutdown()
        XCTAssertFalse(try controlledArtifactsContain(Data(purgeSentinel.utf8)))

        let sessionSentinel = "session-byte-sentinel-\(UUID().uuidString)"
        store = try makeStore(policy: .days30)
        _ = try await store?.recordFinal(.init(text: sessionSentinel))
        try await store?.setRetentionPolicy(.session)
        await store?.shutdown()
        XCTAssertFalse(try controlledArtifactsContain(Data(sessionSentinel.utf8)))
    }

    func testTenThousandRecordSearchAndPurgeAcceptance() async throws {
        let fixturePrefix = "rd-10k-\(UUID().uuidString)"
        let externalTempBefore = try topLevelTemporaryArtifacts()
        var setup: SQLiteHistoryStore? = try makeStore(policy: .days30)
        try await setup?.warmUp()
        await setup?.shutdown()
        setup = nil
        try seedFixtures(count: 10_000, prefix: fixturePrefix)

        let store = try SQLiteHistoryStore(directoryURL: directory, policy: .off, now: { self.now })
        let coldStarted = ContinuousClock.now
        let coldRows = try await store.records(limit: 25)
        let coldMilliseconds = milliseconds(since: coldStarted)
        XCTAssertEqual(coldRows.count, 25)
        XCTAssertLessThanOrEqual(coldMilliseconds, 100, "10k cold list was \(coldMilliseconds) ms")

        let detachedList = try await Task.detached {
            let started = ContinuousClock.now
            let rows = try await store.records(limit: 25)
            return (pthread_main_np() != 0, rows.count, started.duration(to: .now))
        }.value
        XCTAssertFalse(detachedList.0, "10k list acceptance ran on the main thread")
        XCTAssertEqual(detachedList.1, 25)
        let detachedMilliseconds =
            Double(detachedList.2.components.seconds) * 1_000
            + Double(detachedList.2.components.attoseconds) / 1_000_000_000_000_000
        XCTAssertLessThanOrEqual(
            detachedMilliseconds,
            100
        )

        var queryDurations: [Double] = []
        for _ in 0..<20 {
            let started = ContinuousClock.now
            let records = try await store.records(query: "cafe", limit: 25)
            queryDurations.append(milliseconds(since: started))
            XCTAssertEqual(records.count, 25)
        }
        let p95 = queryDurations.sorted()[18]
        XCTAssertLessThanOrEqual(p95, 100, "10k warm query p95 was \(p95) ms")
        fputs(
            "RD-I07 macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "memory=\(ProcessInfo.processInfo.physicalMemory) "
                + "sqlite=\(String(cString: sqlite3_libversion())) fixture=10000 "
                + "cold_ms=\(coldMilliseconds) list_ms=\(detachedMilliseconds) p95_ms=\(p95)\n",
            stderr
        )

        now += HistoryRetentionPolicy.days30.durationMilliseconds! + 20_000
        let purgeStarted = ContinuousClock.now
        try await store.purgeExpired()
        let purgeMilliseconds = milliseconds(since: purgeStarted)
        XCTAssertLessThan(purgeMilliseconds, 30_000, "10k purge exceeded idle-maintenance budget")
        let remaining = try await store.records()
        XCTAssertTrue(remaining.isEmpty)
        await store.shutdown()
        XCTAssertFalse(try controlledArtifactsContain(Data("\(fixturePrefix)-0".utf8)))
        XCTAssertFalse(try controlledArtifactsContain(Data("\(fixturePrefix)-9999".utf8)))
        let newExternalArtifacts = try topLevelTemporaryArtifacts().subtracting(externalTempBefore)
        for artifact in newExternalArtifacts where !artifact.path.hasPrefix(directory.path) {
            let values = try? artifact.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= 10_000_000,
                  let data = try? Data(contentsOf: artifact)
            else { continue }
            XCTAssertNil(data.range(of: Data(fixturePrefix.utf8)), "external temp leaked fixture sentinel")
        }
    }

    func testConcurrentReadsWritesDeletesAndPolicyChangesRemainSerialized() async throws {
        let store = try makeStore(policy: .days30)
        let initial = try await store.recordFinal(.init(text: "concurrency-seed"))
        let seedID = try XCTUnwrap(initial?.id)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<120 {
                group.addTask {
                    do {
                        switch index % 4 {
                        case 0:
                            _ = try await store.recordFinal(.init(text: "concurrent-\(index)"))
                        case 1:
                            _ = try await store.records(query: "concurrent", limit: 25)
                        case 2:
                            _ = try await store.delete(id: seedID)
                        default:
                            try await store.setRetentionPolicy(index.isMultiple(of: 8) ? .days7 : .days30)
                        }
                    } catch {
                        XCTFail("serialized actor operation leaked error: \(error)")
                    }
                }
            }
        }
        let records = try await store.records(limit: 25)
        XCTAssertLessThanOrEqual(records.count, 25)
        XCTAssertFalse(records.contains(where: { $0.id == seedID }))
    }

    func testSchemaZeroCreationRollsBackAtomicallyOnInjectedFailure() async throws {
        let failing = try SQLiteHistoryStore(
            directoryURL: directory,
            policy: .days30,
            now: { self.now },
            testSchemaCreationFailure: true
        )
        await XCTAssertThrowsErrorAsync(try await failing.warmUp()) { error in
            XCTAssertEqual(error as? HistoryStoreError, .migrationFailed)
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(
            directory.appendingPathComponent(SQLiteHistoryStore.databaseName).path,
            &handle,
            SQLITE_OPEN_READONLY,
            nil
        ), SQLITE_OK)
        defer { if let handle { sqlite3_close_v2(handle) } }
        XCTAssertEqual(try pragmaInt("user_version", database: handle), 0)
        XCTAssertEqual(try schemaObjectCount(database: handle), 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains("backup") || $0.contains("migration") }))
    }

    func testStoreIsExcludedFromBackupAndSpotlightDiscovery() async throws {
        let sentinel = "spotlight-private-\(UUID().uuidString)"
        let store = try makeStore()
        _ = try await store.recordFinal(.init(text: sentinel))
        await store.shutdown()

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".metadata_never_index").path
        ))

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", directory.path, sentinel]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let result = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testExternalDeadlineInterruptRollsBackWithoutLateRow() async throws {
        let store = try SQLiteHistoryStore(
            directoryURL: directory,
            policy: .days30,
            now: { self.now },
            testPreCommitDelayMicroseconds: 300_000
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let cancellation = HistoryWriteCancellation()
        let attempt = Task {
            try await store.recordFinal(
                .init(text: "must never become a late row"),
                deadlineUptimeNanoseconds: deadline,
                cancellation: cancellation
            )
        }

        // This does not await the actor: it uses the same nonisolated path the
        // 100 ms delivery gate uses while SQLite is executing synchronously.
        try await Task.sleep(nanoseconds: 30_000_000)
        cancellation.interrupt()

        await XCTAssertThrowsErrorAsync(try await attempt.value) { error in
            XCTAssertEqual(error as? HistoryStoreError, .deadlineExceeded)
        }
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty, "an interrupted pre-delivery write must never commit later")
    }

    func testQueuedWritePastDeadlineNeverCommitsLate() async throws {
        let store = try SQLiteHistoryStore(
            directoryURL: directory,
            policy: .days30,
            now: { self.now },
            testPreCommitDelayMicroseconds: 180_000
        )
        let first = Task { try await store.recordFinal(.init(text: "first writer")) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let expiredWhileQueued = DispatchTime.now().uptimeNanoseconds + 40_000_000
        await XCTAssertThrowsErrorAsync(
            try await store.recordFinal(.init(text: "queued late writer"), deadlineUptimeNanoseconds: expiredWhileQueued)
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError, .deadlineExceeded)
        }
        _ = try await first.value
        let later = try await store.recordFinal(.init(text: "later writer"))
        let records = try await store.records()
        XCTAssertEqual(Set(records.map(\.text)), Set(["later writer", "first writer"]))
        XCTAssertEqual(later?.text, "later writer")
    }

    func testAdvisoryLockFailsClosedRatherThanSharingWriter() async throws {
        let first = try makeStore()
        _ = try await first.recordFinal(.init(text: "lock holder"))
        let second = try SQLiteHistoryStore(directoryURL: directory, policy: .days30, now: { self.now })
        await XCTAssertThrowsErrorAsync(try await second.records()) { error in
            XCTAssertEqual(error as? HistoryStoreError, .busy)
        }
    }

    func testDatabaseSymlinkAttackFailsClosed() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent)-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data("foreign".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        XCTAssertEqual(symlink(outside.path, directory.appendingPathComponent(SQLiteHistoryStore.databaseName).path), 0)
        let store = try makeStore()

        await XCTAssertThrowsErrorAsync(try await store.warmUp()) { error in
            XCTAssertEqual(error as? HistoryStoreError, .unsupportedFilesystem)
        }
    }

    func testRecordCapAndLimitClamp() async throws {
        let store = try makeStore()
        await XCTAssertThrowsErrorAsync(try await store.recordFinal(.init(text: String(repeating: "x", count: 100_001)))) { error in
            XCTAssertEqual(error as? HistoryStoreError, .recordTooLarge)
        }
        for index in 0..<26 { _ = try await store.recordFinal(.init(text: "row \(index)")) }
        let zeroLimit = try await store.records(limit: 0)
        let negativeLimit = try await store.records(limit: -10)
        let largeLimit = try await store.records(limit: 1_000)
        XCTAssertEqual(zeroLimit.count, 1)
        XCTAssertEqual(negativeLimit.count, 1)
        XCTAssertEqual(largeLimit.count, 25)
    }

    func testExpiredPreDeliveryDeadlineCreatesNoStoreOrLateRecord() async throws {
        let store = try makeStore()
        let expiredDeadline = DispatchTime.now().uptimeNanoseconds - 1

        await XCTAssertThrowsErrorAsync(
            try await store.recordFinal(.init(text: "must not commit"), deadlineUptimeNanoseconds: expiredDeadline)
        ) { error in
            XCTAssertEqual(error as? HistoryStoreError, .deadlineExceeded)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOffRemovesSentinelBearingStoreAfterTruncatingCleanup() async throws {
        let store = try makeStore()
        let sentinel = "RD-SENTINEL-\(UUID().uuidString)"
        _ = try await store.recordFinal(.init(text: sentinel))

        try await store.setRetentionPolicy(.off)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeStore(policy: HistoryRetentionPolicy = .days30) throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(directoryURL: directory, policy: policy, now: { self.now })
    }

    private func controlledArtifactsContain(_ sentinel: Data) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            if data.range(of: sentinel) != nil { return true }
        }
        return false
    }

    private func topLevelTemporaryArtifacts() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ))
    }

    private func runCrashSubprocess(
        test: String,
        environment additions: [String: String]
    ) throws -> (reason: Process.TerminationReason, status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
        )
        process.arguments = ["-XCTest", test, Bundle(for: type(of: self)).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in additions { environment[key] = value }
        process.environment = environment
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile()
                + standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return (process.terminationReason, process.terminationStatus, output)
    }

    private func pragmaInt(_ name: String, database: OpaquePointer?) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStoreError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HistoryStoreError.unavailable }
        return sqlite3_column_int(statement, 0)
    }

    private func schemaObjectCount(database: OpaquePointer?) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw HistoryStoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HistoryStoreError.unavailable }
        return sqlite3_column_int(statement, 0)
    }

    private func seedFixtures(count: Int, prefix: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            directory.appendingPathComponent(SQLiteHistoryStore.databaseName).path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK else { throw HistoryStoreError.unavailable }
        defer { if let database { sqlite3_close_v2(database) } }
        guard sqlite3_exec(database, "PRAGMA secure_delete=ON; BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw HistoryStoreError.unavailable
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            INSERT INTO records
              (id, created_at_ms, expires_at_ms, text, delivery_state, delivery_updated_at_ms)
            VALUES (?, ?, ?, ?, 'pending', NULL)
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw HistoryStoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        for index in 0..<count {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let created = now + Int64(index)
            let id = "fixture-id-\(index)"
            let text = "\(prefix)-\(index) cafe مرحبا literal AND quote\""
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT_TEST)
            sqlite3_bind_int64(statement, 2, created)
            sqlite3_bind_int64(statement, 3, created + HistoryRetentionPolicy.days30.durationMilliseconds!)
            sqlite3_bind_text(statement, 4, text, -1, SQLITE_TRANSIENT_TEST)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStoreError.unavailable }
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw HistoryStoreError.unavailable
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

private let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
