import AppKit
import XCTest
@testable import Saymark

@MainActor
final class HUDPanelIntegrationTests: XCTestCase {
    func testProductionAnimatorMakesHotkeyFeedbackImmediatelyVisible() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.alphaValue = 0
        defer { panel.orderOut(nil) }

        AppKitHUDAnimator().show(panel)

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
    }

    func testPanelUsesExpectedNonActivatingOverlayConfiguration() throws {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")

        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    func testPanelHostsSwiftUIViewAtExpectedSize() throws {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")

        let panel = try XCTUnwrap(controller.panel)
        let host = try XCTUnwrap(panel.contentView)
        XCTAssertTrue(String(describing: type(of: host)).contains("NSHostingView"))
        XCTAssertEqual(host.frame.size.width, 940, accuracy: 0.1)
        XCTAssertEqual(host.frame.size.height, 260, accuracy: 0.1)
        XCTAssertTrue(host.autoresizingMask.contains(.width))
        XCTAssertTrue(host.autoresizingMask.contains(.height))
    }

    func testCompletedHideDestroysHostedViewAndReleasesPanel() {
        let (controller, scheduler, animator) = makeHUDController()
        controller.begin(presentation: false, lang: "Auto")
        controller.finish("done")
        let panel = controller.panel

        scheduler.fire(0)
        XCTAssertTrue(animator.hiddenPanels.first === panel)
        XCTAssertNotNil(panel?.contentView)

        animator.completeHide()

        XCTAssertNil(panel?.contentView)
        XCTAssertNil(controller.panel)
    }

    func testLongFinalStillDestroysScrollableHostedViewAndReleasesPanel() {
        let (controller, scheduler, animator) = makeHUDController()
        controller.begin(presentation: false, lang: "Auto")
        let finalText = Array(
            repeating: "This long dictated passage remains wrapped and scrollable until teardown.",
            count: 30
        ).joined(separator: " ")
        controller.finish(finalText)
        let panel = controller.panel

        XCTAssertEqual(controller.model.transcriptAccessibilityLabel, finalText)
        XCTAssertTrue(controller.model.usesScrollableTranscript)
        XCTAssertNotNil(panel?.contentView)

        scheduler.fire(0)
        animator.completeHide()

        XCTAssertNil(panel?.contentView)
        XCTAssertNil(controller.panel)
    }

    func testNextPresentationCreatesFreshPanelAndViewTreeAfterTeardown() {
        let (controller, scheduler, animator) = makeHUDController()
        controller.begin(presentation: false, lang: "Auto")
        let firstPanel = controller.panel
        let firstView = firstPanel?.contentView
        controller.finish("done")
        scheduler.fire(0)
        animator.completeHide()

        controller.begin(presentation: false, lang: "Auto")
        defer { tearDownHUD(controller) }

        XCTAssertFalse(controller.panel === firstPanel)
        XCTAssertFalse(controller.panel?.contentView === firstView)
        XCTAssertNotNil(controller.panel?.contentView)
    }

    func testProductionSchedulerStartsHideAfterDeadline() async {
        let animator = ManualHUDAnimator()
        let controller = HUDController(scheduler: DispatchHUDHideScheduler(), animator: animator)
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")
        controller.finish("done")

        let didStartHiding = await waitForHUDCondition(timeout: .seconds(5)) {
            animator.hiddenPanels.count == 1
        }
        XCTAssertTrue(didStartHiding)
        animator.completeHide()
        XCTAssertNil(controller.panel)
    }
}
