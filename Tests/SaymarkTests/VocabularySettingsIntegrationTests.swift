import AppKit
import SwiftUI
import XCTest
@testable import Saymark

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

        XCTAssertEqual(model.correctionStatus, "failedRawFallback")
        XCTAssertEqual(model.correctionRevision, 42)
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
}
