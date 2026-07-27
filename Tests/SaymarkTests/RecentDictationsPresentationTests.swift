import AppKit
import XCTest
@testable import Saymark
@testable import SaymarkKit

@MainActor
final class RecentDictationsPresentationTests: XCTestCase {
    override func tearDown() {
        RecentDictationsController.shared.resetReinsertSeamsForTesting()
        RecentDictationsController.shared.setPreviousApplicationForTesting(nil)
        RecentDictationsController.shared.setRecordsForTesting([])
        super.tearDown()
    }

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

    func testSearchAndTranscriptControlsDisableLearningAndRecents() {
        let search = makePrivateHistorySearchField()
        XCTAssertNil(search.recentsAutosaveName)
        XCTAssertEqual(search.accessibilityIdentifier(), "recent-dictations.search")

        let text = NSTextView()
        configurePrivateHistoryTextView(text)
        XCTAssertFalse(text.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(text.isGrammarCheckingEnabled)
        XCTAssertFalse(text.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(text.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(text.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(text.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(text.isAutomaticTextCompletionEnabled)
    }

    func testReinsertPinsTargetPIDAndPostsExactTextOnce() async throws {
        let controller = RecentDictationsController.shared
        let target = NSRunningApplication.current
        let record = makeRecord(text: "exact reinsert text")
        var activatedPID: pid_t?
        var pasted: [String] = []
        var announcements: [String] = []
        controller.setPreviousApplicationForTesting(target)
        controller.allowSelfReinsertTargetForTesting = true
        controller.reinsertAccessibilityTrusted = { true }
        controller.reinsertSecureInputActive = { false }
        controller.reinsertActivate = { activatedPID = $0.processIdentifier }
        controller.reinsertFrontmostPID = { target.processIdentifier }
        controller.reinsertPaste = { pasted.append($0); return .pasted }
        controller.reinsertDelay = 0.01
        controller.announcementSink = { announcements.append($0) }

        controller.requestReinsert(record)
        controller.confirmReinsert()
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(activatedPID, target.processIdentifier)
        XCTAssertEqual(pasted, [record.text])
        XCTAssertEqual(controller.errorMessage, "Reinserted into \(target.localizedName ?? "the selected app").")
        XCTAssertEqual(announcements.last, "Dictation reinserted.")
    }

    func testReinsertPIDMismatchNeverPostsAndCopiesFallback() async throws {
        let controller = RecentDictationsController.shared
        let target = NSRunningApplication.current
        let record = makeRecord(text: "pid mismatch fallback")
        var pasteCalls = 0
        controller.setPreviousApplicationForTesting(target)
        controller.allowSelfReinsertTargetForTesting = true
        controller.reinsertAccessibilityTrusted = { true }
        controller.reinsertSecureInputActive = { false }
        controller.reinsertActivate = { _ in }
        controller.reinsertFrontmostPID = { target.processIdentifier + 1 }
        controller.reinsertPaste = { _ in pasteCalls += 1; return .pasted }
        controller.reinsertDelay = 0.01

        controller.requestReinsert(record)
        controller.confirmReinsert()
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(pasteCalls, 0)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), record.text)
        XCTAssertEqual(controller.errorMessage, "That app is no longer active. The text was copied instead.")
    }

    func testReinsertPasteFailureCopiesExactTextWithoutRetry() async throws {
        let controller = RecentDictationsController.shared
        let target = NSRunningApplication.current
        let record = makeRecord(text: "failed paste exact fallback")
        var pasteCalls = 0
        controller.setPreviousApplicationForTesting(target)
        controller.allowSelfReinsertTargetForTesting = true
        controller.reinsertAccessibilityTrusted = { true }
        controller.reinsertSecureInputActive = { false }
        controller.reinsertActivate = { _ in }
        controller.reinsertFrontmostPID = { target.processIdentifier }
        controller.reinsertPaste = { _ in pasteCalls += 1; return .failed }
        controller.reinsertDelay = 0.01

        controller.requestReinsert(record)
        controller.confirmReinsert()
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(pasteCalls, 1)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), record.text)
        XCTAssertEqual(controller.errorMessage, "Couldn’t paste text. The text was copied.")
    }

    func testReinsertAccessibilityAndSecureInputFallbackBeforeActivation() {
        let controller = RecentDictationsController.shared
        let target = NSRunningApplication.current
        let record = makeRecord(text: "protected fallback")
        var activations = 0
        controller.setPreviousApplicationForTesting(target)
        controller.allowSelfReinsertTargetForTesting = true
        controller.reinsertActivate = { _ in activations += 1 }
        controller.reinsertAccessibilityTrusted = { false }

        controller.requestReinsert(record)
        controller.confirmReinsert()
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), record.text)
        XCTAssertEqual(controller.errorMessage, "Accessibility is needed to reinsert. The text was copied.")

        controller.reinsertAccessibilityTrusted = { true }
        controller.reinsertSecureInputActive = { true }
        controller.requestReinsert(record)
        controller.confirmReinsert()
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(controller.errorMessage, "The current field is protected. The text was copied.")
    }

    func testProductionReinsertVerificationWindowIsAtMostFiveHundredMilliseconds() {
        let controller = RecentDictationsController.shared
        controller.resetReinsertSeamsForTesting()
        XCTAssertLessThanOrEqual(controller.reinsertDelay, 0.5)
    }

    func testPrivateSurfacesDoNotPersistTranscriptOrSearchSentinels() throws {
        let sentinel = "surface-private-\(UUID().uuidString)"
        let record = makeRecord(text: sentinel)
        XCTAssertTrue(RecentDictationsController.shared.copy(record))

        XCTAssertFalse(
            contains(sentinel, in: UserDefaults.standard.dictionaryRepresentation())
        )
        let window = RecentDictationsController.shared.makeWindowForTesting()
        XCTAssertEqual(window.title, "Recent Dictations")
        XCTAssertFalse(window.title.contains(sentinel))
    }

    func testHistoryPagingStartsAtTwentyAndOffersOnlyFiveMore() {
        let controller = RecentDictationsController.shared
        controller.setRecordsForTesting((0..<20).map { makeRecord(text: "row \($0)") })
        XCTAssertTrue(controller.canLoadMore)
        controller.setRecordsForTesting((0..<19).map { makeRecord(text: "row \($0)") })
        XCTAssertFalse(controller.canLoadMore)
    }

    func testRecentDictationsSourcesContainNoPostHogOrHardcodedLibraryPath() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relative in [
            "Sources/Saymark/RecentDictationsController.swift",
            "Sources/Saymark/RecentDictationsView.swift",
            "Sources/Saymark/SettingsView.swift",
        ] {
            let source = try String(
                contentsOf: repository.appendingPathComponent(relative),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("PostHog"))
            XCTAssertFalse(source.contains("Library/Application Support"))
            XCTAssertFalse(source.contains("character_count"))
            XCTAssertFalse(source.contains("word_count"))
        }
    }

    private func makeRecord(text: String) -> HistoryRecord {
        HistoryRecord(
            id: UUID().uuidString,
            createdAtMilliseconds: 1,
            expiresAtMilliseconds: nil,
            text: text,
            deliveryState: .inserted,
            deliveryUpdatedAtMilliseconds: 2
        )
    }

    private func contains(_ sentinel: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string.contains(sentinel)
        }
        if let data = value as? Data {
            return data.range(of: Data(sentinel.utf8)) != nil
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains {
                $0.key.contains(sentinel) || contains(sentinel, in: $0.value)
            }
        }
        if let array = value as? [Any] {
            return array.contains { contains(sentinel, in: $0) }
        }
        return false
    }
}
