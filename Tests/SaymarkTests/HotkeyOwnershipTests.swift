import XCTest
import SaymarkKit
@testable import Saymark

@MainActor
final class HotkeyOwnershipTests: XCTestCase {
    func testOnboardingHandoffIsIdempotentAndCanBeReclaimed() {
        let controller = DictationController()

        XCTAssertEqual(controller.hotkeyOwner, .runtime)

        var handoffs = 0
        controller.handOffHotkeyToOnboarding { handoffs += 1 }
        controller.handOffHotkeyToOnboarding { handoffs += 1 }
        XCTAssertEqual(controller.hotkeyOwner, .onboarding)
        XCTAssertEqual(handoffs, 2)

        controller.reclaimHotkeyFromOnboarding()
        XCTAssertEqual(controller.hotkeyOwner, .runtime)
    }

    func testOnboardingHotkeyCannotStartCaptureOutsideTryItStep() {
        let controller = DictationController()
        let onboarding = OnboardingModel(session: controller.dictationSession)
        onboarding.modelsReady = true

        for step in [
            OnboardingFlow.Step.welcome,
            .permissions,
            .shortcut,
            .download,
            .done,
        ] {
            onboarding.flow.step = step
            onboarding.tryHotkeyDown()
            XCTAssertFalse(onboarding.tryListening, "capture started on \(step)")
        }
    }
}
