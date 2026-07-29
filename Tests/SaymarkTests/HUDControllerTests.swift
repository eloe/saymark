import AppKit
import XCTest
@testable import Saymark

@MainActor
final class HUDControllerTests: XCTestCase {
    func testBeginResetsModelAndConfiguresInteractivePanel() {
        let (controller, _, animator) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.error("old error")
        controller.update(confirmed: "old", partial: "text")
        var stopped = false
        controller.begin(presentation: true, lang: "fr", interactive: true) { stopped = true }

        XCTAssertEqual(controller.model.phase, .listening)
        XCTAssertEqual(controller.model.confirmed, "")
        XCTAssertEqual(controller.model.partial, "")
        XCTAssertEqual(controller.model.lang, "fr")
        XCTAssertTrue(controller.model.presentation)
        XCTAssertTrue(controller.model.recording)
        XCTAssertTrue(controller.model.showStop)
        XCTAssertFalse(controller.panel?.ignoresMouseEvents ?? true)
        XCTAssertEqual(animator.shownPanels.count, 2)
        controller.model.onStop()
        XCTAssertTrue(stopped)
    }

    func testNonInteractiveBeginIgnoresMouseEvents() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.begin(presentation: false, lang: "Auto")

        XCTAssertTrue(controller.panel?.ignoresMouseEvents ?? false)
        XCTAssertFalse(controller.model.showStop)
    }

    func testToggleModeHaloFollowsListeningAndSuccessfulCompletion() {
        let scheduler = ManualHUDScheduler()
        let animator = ManualHUDAnimator()
        let halo = ManualListeningHalo()
        let controller = HUDController(scheduler: scheduler, animator: animator, halo: halo)
        defer { tearDownHUD(controller) }

        controller.begin(presentation: false, lang: "Auto", interactive: true)

        XCTAssertEqual(halo.beginCount, 1)
        XCTAssertTrue(controller.isListeningHaloVisible)

        controller.processing()

        XCTAssertEqual(halo.stopCount, 1)
        XCTAssertFalse(controller.isListeningHaloVisible)

        controller.finish("Finished words")

        XCTAssertEqual(halo.completeCount, 1)
        XCTAssertEqual(halo.dismissCount, 0)
    }

    func testHoldModeNeverShowsHaloAndErrorDismissesIt() {
        let scheduler = ManualHUDScheduler()
        let animator = ManualHUDAnimator()
        let halo = ManualListeningHalo()
        let controller = HUDController(scheduler: scheduler, animator: animator, halo: halo)
        defer { tearDownHUD(controller) }

        controller.begin(presentation: false, lang: "Auto", interactive: false)
        controller.error("denied")

        XCTAssertEqual(halo.beginCount, 0)
        XCTAssertFalse(controller.isListeningHaloVisible)
        XCTAssertEqual(halo.dismissCount, 2)
    }

    func testTranscriptWindowIsBoundedByPresentationMode() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.begin(presentation: false, lang: "Auto")
        XCTAssertEqual(controller.model.transcriptLineLimit, 3)
        XCTAssertEqual(controller.panel?.frame.height, 260)

        controller.begin(presentation: true, lang: "Auto")
        XCTAssertEqual(controller.model.transcriptLineLimit, 6)
        XCTAssertEqual(controller.panel?.frame.height, 380)
    }

    func testUpdateTransitionsBetweenListeningAndTranscribing() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")

        controller.update(confirmed: "hello", partial: "wor")
        XCTAssertEqual(controller.model.phase, .transcribing)
        XCTAssertEqual(controller.model.confirmed, "hello")
        XCTAssertEqual(controller.model.partial, "wor")

        controller.update(confirmed: "", partial: "")
        XCTAssertEqual(controller.model.phase, .listening)
    }

    func testUpdateDoesNotReplaceErrorPhase() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.error("denied")

        controller.update(confirmed: "ignored", partial: "update")

        XCTAssertEqual(controller.model.phase, .error)
        XCTAssertEqual(controller.model.confirmed, "ignored")
        XCTAssertEqual(controller.model.partial, "update")
    }

    func testFinishSchedulesNormalAndPresentationDelays() {
        let (normal, normalScheduler, _) = makeHUDController()
        defer { tearDownHUD(normal) }
        normal.begin(presentation: false, lang: "Auto", interactive: true)
        normal.finish("final words")

        XCTAssertEqual(normalScheduler.entries.last?.delay, 3.2)
        XCTAssertEqual(normal.model.confirmed, "final words")
        XCTAssertEqual(normal.model.partial, "")
        XCTAssertEqual(normal.model.phase, .transcribing)
        XCTAssertTrue(normal.model.showingFinal)
        XCTAssertTrue(normal.model.usesScrollableTranscript)
        XCTAssertNil(normal.model.transcriptLineLimit)
        XCTAssertFalse(normal.model.recording)
        XCTAssertFalse(normal.model.showStop)

        let (presentation, presentationScheduler, _) = makeHUDController()
        defer { tearDownHUD(presentation) }
        presentation.begin(presentation: true, lang: "Auto")
        presentation.finish("")
        XCTAssertEqual(presentationScheduler.entries.last?.delay, 4.0)
        XCTAssertEqual(presentation.model.phase, .listening)
    }

    func testLongFinalTranscriptIsCompleteExpandedScrollableAndReadable() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        let sentence = "Saymark keeps every dictated word available in the final transcript without clipping it."
        let finalText = Array(repeating: sentence, count: 18).joined(separator: " ")
        controller.begin(presentation: false, lang: "Auto")

        controller.finish(finalText)

        XCTAssertEqual(controller.model.confirmed, finalText)
        XCTAssertEqual(controller.model.transcriptAccessibilityLabel, finalText)
        XCTAssertTrue(controller.model.showingFinal)
        XCTAssertTrue(controller.model.requiresExpandedFinal)
        XCTAssertTrue(controller.model.usesScrollableTranscript)
        XCTAssertNil(controller.model.transcriptLineLimit)
        XCTAssertEqual(controller.panel?.frame.height, CGFloat(410))
        XCTAssertFalse(controller.panel?.ignoresMouseEvents ?? true)
        XCTAssertEqual(scheduler.entries.last?.delay, 12.0)
    }

    func testTypicalCorrectedHoldFinalMakesDisclosureInteractive() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "EN", interactive: false)
        XCTAssertTrue(controller.panel?.ignoresMouseEvents ?? false)

        controller.finish(
            "Saymark is ready.",
            rawText: "say mark is ready.",
            correctionStatus: "corrected",
            correctionRevision: 17
        )

        XCTAssertFalse(controller.model.requiresExpandedFinal)
        XCTAssertTrue(controller.model.showsCorrectionDetails)
        XCTAssertTrue(controller.model.allowsFinalInteraction)
        XCTAssertFalse(controller.panel?.ignoresMouseEvents ?? true)
        XCTAssertEqual(scheduler.entries.last?.delay, 8.0)
    }

    func testTypicalFailedRawFallbackHoldFinalMakesDisclosureAndCopyOperable() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "EN", interactive: false)
        let raw = "say mark could not correct this"

        controller.finish(
            raw,
            rawText: raw,
            correctionStatus: "failedRawFallback",
            correctionRevision: 18
        )

        XCTAssertFalse(controller.model.requiresExpandedFinal)
        XCTAssertTrue(controller.model.showsCorrectionDetails)
        XCTAssertTrue(controller.model.allowsFinalInteraction)
        XCTAssertFalse(controller.panel?.ignoresMouseEvents ?? true)
        XCTAssertEqual(scheduler.entries.last?.delay, 8.0)
        controller.model.copyRawTranscript()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), raw)
    }

    func testNewUtteranceStopsFinalModeAndRestoresCompactNonInteractiveHUD() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        let finalText = Array(repeating: "A complete sentence for the expanded result.", count: 12)
            .joined(separator: " ")
        controller.begin(presentation: false, lang: "Auto")
        controller.finish(finalText)

        controller.begin(presentation: false, lang: "Auto")

        XCTAssertFalse(controller.model.showingFinal)
        XCTAssertFalse(controller.model.usesScrollableTranscript)
        XCTAssertEqual(controller.model.transcriptLineLimit, 3)
        XCTAssertEqual(controller.panel?.frame.height, CGFloat(260))
        XCTAssertTrue(controller.panel?.ignoresMouseEvents ?? false)
    }

    func testProcessingMakesReleaseTransitionExplicitWithoutSchedulingHide() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto", interactive: true)

        controller.processing()

        XCTAssertEqual(controller.model.phase, .transcribing)
        XCTAssertEqual(controller.model.confirmed, "")
        XCTAssertEqual(controller.model.partial, "")
        XCTAssertFalse(controller.model.recording)
        XCTAssertFalse(controller.model.showStop)
        XCTAssertTrue(scheduler.entries.isEmpty)
    }

    func testFinishWithoutPanelIsIgnored() {
        let (controller, scheduler, _) = makeHUDController()

        controller.finish("orphan")

        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertEqual(controller.model.confirmed, "")
    }

    func testRepeatedFinishCancelsEarlierDeadline() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")

        controller.finish("first")
        controller.finish("second")

        XCTAssertEqual(scheduler.entries.count, 2)
        XCTAssertTrue(scheduler.entries[0].cancellation.isCancelled)
        XCTAssertFalse(scheduler.entries[1].cancellation.isCancelled)
        scheduler.fire(0)
        XCTAssertNotNil(controller.panel)
    }

    func testErrorSchedulesHideAndPreservesDefaultForEmptyMessage() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.error("")

        XCTAssertEqual(controller.model.phase, .error)
        XCTAssertEqual(controller.model.errorText, "Open Privacy in Settings →")
        XCTAssertFalse(controller.model.recording)
        XCTAssertEqual(scheduler.entries.last?.delay, 3.2)
    }

    func testActionNeededMessageHasSpecificTitleAndLongEnoughLinger() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.error(
            title: "Copied to clipboard",
            detail: "Enable Accessibility to paste automatically",
            hideAfter: 5.0
        )

        XCTAssertEqual(controller.model.phase, .error)
        XCTAssertEqual(controller.model.errorTitle, "Copied to clipboard")
        XCTAssertEqual(controller.model.errorText, "Enable Accessibility to paste automatically")
        XCTAssertEqual(scheduler.entries.last?.delay, 5.0)
    }

    func testBeginCancelsPendingHideAndInvalidatesItsAction() {
        let (controller, scheduler, animator) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.error("denied")
        let oldID = controller.presentationID

        controller.begin(presentation: false, lang: "en")

        XCTAssertTrue(scheduler.entries[0].cancellation.isCancelled)
        XCTAssertGreaterThan(controller.presentationID, oldID)
        scheduler.fire(0, evenIfCancelled: true)
        XCTAssertTrue(animator.hiddenPanels.isEmpty)
        XCTAssertNotNil(controller.panel?.contentView)
    }

    func testBeginPublishesConfiguredShortcutLabel() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.begin(
            presentation: false,
            lang: "Auto",
            shortcutLabel: "⇧⌘D"
        )

        XCTAssertEqual(controller.model.shortcutLabel, "⇧⌘D")
    }

    func testErrorCancelsPendingFinishAndInvalidatesItsAction() {
        let (controller, scheduler, animator) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")
        controller.finish("done")

        controller.error("denied")

        XCTAssertTrue(scheduler.entries[0].cancellation.isCancelled)
        XCTAssertEqual(scheduler.entries[1].delay, 3.2)
        scheduler.fire(0, evenIfCancelled: true)
        XCTAssertTrue(animator.hiddenPanels.isEmpty)
        XCTAssertEqual(controller.model.phase, .error)
    }

    func testStaleFadeCompletionCannotTearDownRePresentedHUD() {
        let (controller, scheduler, animator) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")
        controller.finish("first")
        scheduler.fire(0)
        let originalPanel = controller.panel

        controller.begin(presentation: false, lang: "Auto")
        animator.completeHide()

        XCTAssertTrue(controller.panel === originalPanel)
        XCTAssertNotNil(controller.panel?.contentView)
        XCTAssertEqual(controller.model.phase, .listening)
    }
}
