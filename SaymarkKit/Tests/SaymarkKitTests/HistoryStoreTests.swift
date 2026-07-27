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
        XCTAssertEqual(try await store.updateDeliveryState(id: record.id, to: .inserted), true)
        XCTAssertEqual(try await store.updateDeliveryState(id: record.id, to: .insertionFailed), false)
        XCTAssertEqual(try await store.records().first?.deliveryState, .inserted)
    }

    func testSecureInputAndHUDOnlyAreNeverStored() async throws {
        let store = try makeStore()

        XCTAssertNil(try await store.recordFinal(.init(text: "credential", secureInputActive: true)))
        XCTAssertNil(try await store.recordFinal(.init(text: "hud", isHUDOnly: true)))
        XCTAssertTrue(try await store.records().isEmpty)
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

        XCTAssertEqual(try await store.records(query: "cafe cre").count, 2)
        XCTAssertEqual(try await store.records(query: "AND OR").count, 1)
        XCTAssertEqual(try await store.records(query: "common", limit: 99).count, 25)
    }

    func testShorterRetentionPurgesAndIncreasingDoesNotExtendExistingRows() async throws {
        let store = try makeStore(policy: .untilDeleted)
        let record = try XCTUnwrap(try await store.recordFinal(.init(text: "bounded")))

        try await store.setRetentionPolicy(.days7)
        let sevenDayExpiry = try XCTUnwrap(try await store.records().first?.expiresAtMilliseconds)
        try await store.setRetentionPolicy(.days90)
        XCTAssertEqual(try await store.records().first?.expiresAtMilliseconds, sevenDayExpiry)

        now += HistoryRetentionPolicy.days7.durationMilliseconds! + 1
        try await store.purgeExpired()
        XCTAssertTrue(try await store.records().isEmpty)
        XCTAssertNotNil(record.id)
    }

    func testDeleteAndClearRemoveSearchableRows() async throws {
        let store = try makeStore()
        let first = try XCTUnwrap(try await store.recordFinal(.init(text: "remove alpha")))
        _ = try await store.recordFinal(.init(text: "remove beta"))

        XCTAssertTrue(try await store.delete(id: first.id))
        XCTAssertTrue(try await store.records(query: "alpha").isEmpty)
        try await store.clear()
        XCTAssertTrue(try await store.records().isEmpty)
        XCTAssertTrue(try await store.records(query: "beta").isEmpty)
    }

    func testRecordCapAndLimitClamp() async throws {
        let store = try makeStore()
        await XCTAssertThrowsErrorAsync(try await store.recordFinal(.init(text: String(repeating: "x", count: 100_001)))) { error in
            XCTAssertEqual(error as? HistoryStoreError, .recordTooLarge)
        }
        for index in 0..<26 { _ = try await store.recordFinal(.init(text: "row \(index)")) }
        XCTAssertEqual(try await store.records(limit: 0).count, 1)
        XCTAssertEqual(try await store.records(limit: -10).count, 1)
        XCTAssertEqual(try await store.records(limit: 1_000).count, 25)
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
