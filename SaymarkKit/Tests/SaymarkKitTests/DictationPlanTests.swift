import XCTest
@testable import SaymarkKit

final class DictationPlanTests: XCTestCase {
    func test_userExperiencesExposeOutcomesNotModelTopology() {
        XCTAssertEqual(DictationExperience.allCases, [.efficient, .livePreview])
        XCTAssertEqual(DictationExperience.efficient.mode, .accurate)
        XCTAssertEqual(DictationExperience.livePreview.mode, .hybrid)
    }

    func test_efficientUsesOnlyTheFinalModel() {
        let plan = DictationPlan.forExperience(.efficient)

        XCTAssertEqual(plan.models.map(\.id), [.parakeet])
        XCTAssertFalse(plan.providesLivePreview)
        XCTAssertEqual(plan.finalModel.id, .parakeet)
    }

    func test_livePreviewAddsDraftModelButKeepsSameFinalAuthority() {
        let efficient = DictationPlan.forExperience(.efficient)
        let live = DictationPlan.forExperience(.livePreview)

        XCTAssertEqual(live.models.map(\.id), [.nemotron, .parakeet])
        XCTAssertTrue(live.providesLivePreview)
        XCTAssertEqual(live.finalModel.id, efficient.finalModel.id)
        XCTAssertEqual(live.estimatedDownloadGB, 3.1, accuracy: 0.001)
    }

    func test_internalFastProfileIsNotAUserExperience() {
        let plan = DictationPlan.forMode(.fast)

        XCTAssertEqual(plan.models.map(\.id), [.nemotron])
        XCTAssertEqual(plan.finalModel.id, .nemotron)
        XCTAssertFalse(DictationExperience.allCases.map(\.mode).contains(.fast))
    }
}
