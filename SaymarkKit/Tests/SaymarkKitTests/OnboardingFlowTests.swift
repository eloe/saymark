import XCTest
@testable import SaymarkKit

final class OnboardingFlowTests: XCTestCase {
    func test_steps_are_six_in_order() {
        XCTAssertEqual(OnboardingFlow.Step.allCases,
                       [.welcome, .permissions, .shortcut, .download, .tryIt, .done])
    }

    func test_permissions_gate_requires_mic_only() {
        var s = OnboardingFlow.State()
        s.step = .permissions
        XCTAssertFalse(OnboardingFlow.canContinue(s))     // no mic
        s.micGranted = true
        XCTAssertTrue(OnboardingFlow.canContinue(s))       // mic alone unblocks (accessibility skippable)
    }

    func test_default_onboarding_plan_downloads_only_efficient_model() {
        let plan = OnboardingFlow.modelPlan

        XCTAssertEqual(plan.mode, .accurate)
        XCTAssertEqual(plan.models.map(\.id), [.parakeet])
        XCTAssertEqual(plan.estimatedDownloadGB, 2.5, accuracy: 0.001)
    }

    func test_plan_progress_gate_uses_only_modelsRequiredByPlan() {
        var s = OnboardingFlow.State()
        s.step = .download
        s.modelFractions[.parakeet] = 0.99
        s.modelFractions[.nemotron] = 1
        XCTAssertFalse(OnboardingFlow.canContinue(s))

        s.modelFractions[.parakeet] = 1
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_plan_download_math_comesFromCatalog() {
        let metrics = OnboardingFlow.downloadMetrics(progress: [.parakeet: 0.5])

        XCTAssertEqual(metrics.downloadedGB, 1.25, accuracy: 0.001)
        XCTAssertEqual(metrics.totalGB, 2.5, accuracy: 0.001)
        XCTAssertEqual(metrics.remainingGB, 1.25, accuracy: 0.001)
        XCTAssertFalse(metrics.done)
    }

    func test_tryit_gate_requires_a_success() {
        var s = OnboardingFlow.State()
        s.step = .tryIt
        XCTAssertFalse(OnboardingFlow.canContinue(s))
        s.didTry = true
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_other_steps_never_block() {
        for step in [OnboardingFlow.Step.welcome, .shortcut, .done] {
            var s = OnboardingFlow.State(); s.step = step
            XCTAssertTrue(OnboardingFlow.canContinue(s))
        }
    }

    func test_next_and_back_clamp() {
        XCTAssertEqual(OnboardingFlow.next(.welcome), .permissions)
        XCTAssertEqual(OnboardingFlow.next(.done), .done)        // clamps
        XCTAssertEqual(OnboardingFlow.back(.permissions), .welcome)
        XCTAssertEqual(OnboardingFlow.back(.welcome), .welcome)  // clamps
    }
}
