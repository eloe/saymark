import Foundation
import XCTest
@testable import SaymarkKit

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var now: Int64!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saymark-history-\(UUID().uuidString)", isDirectory: true)
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

    func testExternalDeadlineInterruptRollsBackWithoutLateRow() async throws {
        let store = try SQLiteHistoryStore(
            directoryURL: directory,
            policy: .days30,
            now: { self.now },
            testPreCommitDelayMicroseconds: 300_000
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let attempt = Task {
            try await store.recordFinal(.init(text: "must never become a late row"), deadlineUptimeNanoseconds: deadline)
        }

        // This does not await the actor: it uses the same nonisolated path the
        // 100 ms delivery gate uses while SQLite is executing synchronously.
        try await Task.sleep(nanoseconds: 30_000_000)
        store.interruptActiveWrite()

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
        let records = try await store.records()
        XCTAssertEqual(records.map(\.text), ["first writer"])
    }

    func testAdvisoryLockFailsClosedRatherThanSharingWriter() async throws {
        let first = try makeStore()
        _ = try await first.recordFinal(.init(text: "lock holder"))
        let second = try SQLiteHistoryStore(directoryURL: directory, policy: .days30, now: { self.now })
        await XCTAssertThrowsErrorAsync(try await second.records()) { error in
            XCTAssertEqual(error as? HistoryStoreError, .busy)
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
