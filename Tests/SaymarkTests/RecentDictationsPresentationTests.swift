import AppKit
import XCTest
@testable import Saymark
@testable import SaymarkKit

@MainActor
final class RecentDictationsPresentationTests: XCTestCase {
    func testHistoryWindowIsPrivateAndNonRestorable() {
        let window = RecentDictationsController.shared.makeWindowForTesting()

        XCTAssertEqual(window.sharingType, .none)
        XCTAssertFalse(window.isRestorable)
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    func testPreviewIsBoundedButSelectedValueRemainsExact() {
        let exact = String(repeating: "private words ", count: 40)

        XCTAssertLessThanOrEqual(exact.historyExcerpt.count, 181)
        XCTAssertTrue(exact.historyExcerpt.hasSuffix("…"))
        XCTAssertGreaterThan(exact.count, exact.historyExcerpt.count)
        XCTAssertEqual(String(exact.prefix(180)) + "…", exact.historyExcerpt)
    }

    func testCopyWritesExactTextToPasteboard() {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let record = HistoryRecord(
            id: "local-test-record",
            createdAtMilliseconds: 1,
            expiresAtMilliseconds: nil,
            text: "exact copied text",
            deliveryState: .inserted,
            deliveryUpdatedAtMilliseconds: 2
        )

        XCTAssertTrue(RecentDictationsController.shared.copy(record))
        XCTAssertEqual(pasteboard.string(forType: .string), record.text)
    }
}
