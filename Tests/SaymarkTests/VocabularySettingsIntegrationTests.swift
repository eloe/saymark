import AppKit
import SaymarkKit
import SwiftUI
import XCTest
@testable import Saymark

private final class CorrectedObserverFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: CorrectedHUDObserver.Handler?

    func observe(_ handler: @escaping CorrectedHUDObserver.Handler) -> () -> Void {
        lock.withLock { self.handler = handler }
        return { [weak self] in self?.lock.withLock { self?.handler = nil } }
    }

    func publish(_ confirmed: CorrectedTranscript, _ partial: CorrectedTranscript) {
        let current = lock.withLock { handler }
        current?(confirmed, partial)
    }
}

private final class CorrectedReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func snapshot() -> [String] { lock.withLock { values } }
}

@MainActor
final class VocabularySettingsIntegrationTests: XCTestCase {
    func testVocabularySectionHostsAsNativeSwiftUIViewAndExposesAccessibilityRoot() {
        let host = NSHostingView(rootView: Form { VocabularySettingsSection() })
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(String(describing: type(of: host)).contains("NSHostingView"))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testCorrectionReviewCarriesStatusAndVocabularyRevision() {
        let model = HUDModel()
        model.correctionStatus = "failedRawFallback"
        model.correctionRevision = 42
        model.showingFinal = true
        model.confirmed = "raw final"
        model.rawTranscript = "raw final"

        XCTAssertEqual(model.correctionStatus, "failedRawFallback")
        XCTAssertEqual(model.correctionRevision, 42)
        XCTAssertTrue(model.showsCorrectionDetails)
        XCTAssertEqual(
            model.correctionSummary,
            "Vocabulary correction was unavailable. Your raw transcript was kept. Vocabulary revision 42."
        )
        XCTAssertFalse(model.correctionSummary.contains("failedRawFallback"))
    }

    func testApplicationHUDObserverConsumesOnlyCorrectionCompleteUpdates() throws {
        let fixture = CorrectedObserverFixture()
        let receipt = CorrectedReceipt()
        let observer = CorrectedHUDObserver(
            observe: fixture.observe,
            receive: { confirmed, partial in
                receipt.append(confirmed.renderedText + partial.renderedText)
            }
        )
        fixture.publish(
            CorrectedTranscript(
                rawText: "",
                renderedText: "",
                snapshotRevision: 9,
                appliedRuleCount: 0
            ),
            CorrectedTranscript(
                rawText: "say mark",
                renderedText: "Saymark",
                snapshotRevision: 9,
                appliedRuleCount: 1
            )
        )

        XCTAssertEqual(receipt.snapshot(), ["Saymark"])
        withExtendedLifetime(observer) {}

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Saymark/DictationController.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("session.observeUpdates"))
        XCTAssertTrue(source.contains("session.observeCorrectedUpdates"))
    }

    func testPostHogCompletionPayloadCannotDependOnCorrectedTextLength() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Saymark/DictationController.swift"),
            encoding: .utf8
        )
        let marker = "PostHogSDK.shared.capture(\"dictation_completed\""
        let payload = try XCTUnwrap(source.range(of: marker)).lowerBound
        let tail = source[payload...].prefix(500)
        XCTAssertFalse(tail.contains("word_count"))
        XCTAssertFalse(tail.contains("character_count"))
        XCTAssertFalse(tail.contains("rawText"))
    }

    func testImportDiffPresentationShowsExactIdentityAndEveryChangedField() throws {
        let id = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
        let oldCreated = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        let newCreated = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-02-03T04:05:06Z"))
        let oldModified = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-04T05:06:07Z"))
        let newModified = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-05T06:07:08Z"))
        let old = VocabularyEntry(
            id: id,
            kind: .vocabulary,
            written: "Say mark",
            heard: ["say mark"],
            enabled: true,
            createdAt: oldCreated,
            updatedAt: oldModified
        )
        let new = VocabularyEntry(
            id: id,
            kind: .replacement,
            written: "Saymark",
            heard: ["saymark", "say mark"],
            enabled: false,
            createdAt: newCreated,
            updatedAt: newModified
        )

        XCTAssertEqual(
            VocabularyImportDiffPresentation.lines(id: id, old: old, new: new),
            [
                "Change: Updated",
                "ID: 12345678-1234-1234-1234-123456789ABC",
                "Kind: vocabulary → replacement",
                "Write: Say mark → Saymark",
                "When I say: say mark → saymark, say mark",
                "Enabled: Enabled → Disabled",
                "Created: 2026-01-02T03:04:05.000Z → 2026-02-03T04:05:06.000Z",
                "Modified: 2026-03-04T05:06:07.000Z → 2026-04-05T06:07:08.000Z",
            ]
        )

        for lines in [
            VocabularyImportDiffPresentation.lines(id: id, old: nil, new: new),
            VocabularyImportDiffPresentation.lines(id: id, old: old, new: nil),
        ] {
            XCTAssertEqual(lines.count, 8)
            XCTAssertEqual(lines[1], "ID: 12345678-1234-1234-1234-123456789ABC")
            XCTAssertTrue(lines.contains(where: { $0.hasPrefix("Kind: ") }))
            XCTAssertTrue(lines.contains(where: { $0.hasPrefix("Write: ") }))
            XCTAssertTrue(lines.contains(where: { $0.hasPrefix("When I say: ") }))
            XCTAssertTrue(lines.contains(where: { $0.hasPrefix("Enabled: ") }))
            XCTAssertTrue(lines.contains(where: { $0.hasPrefix("Created: ") }))
            XCTAssertTrue(lines.contains(where: { $0.hasPrefix("Modified: ") }))
        }
    }
}
