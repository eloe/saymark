import Foundation

/// Pure, UI-agnostic state + rules for the first-run onboarding wizard. The app's
/// `OnboardingModel` owns the real subsystems and consults this for every
/// transition and gate. Foundation-only so it unit-tests without MLX.
public enum OnboardingFlow {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, permissions, shortcut, download, tryIt, done
    }

    /// First-run installs the resource-efficient experience. The optional live
    /// preview model is downloaded lazily only if the user enables that experience.
    public static let modelPlan = DictationPlan.forExperience(.efficient)
    public static var totalGB: Double { modelPlan.estimatedDownloadGB }

    public struct State: Sendable {
        public var step: Step = .welcome
        public var micGranted = false
        public var accessibilityGranted = false
        public var modelFractions: [SaymarkModelID: Double] = [:]
        public var didTry = false           // ≥1 successful try-it dictation
        public init() {}
    }

    /// Continue is allowed unless the current step has an unmet requirement.
    /// Mic is required (no dictation without it); Accessibility is *not* gated
    /// (skippable — HUD-only works without it).
    public static func canContinue(_ s: State) -> Bool {
        switch s.step {
        case .permissions: return s.micGranted
        case .download:
            return modelPlan.models.allSatisfy { s.modelFractions[$0.id, default: 0] >= 1 }
        case .tryIt:       return s.didTry
        case .welcome, .shortcut, .done: return true
        }
    }

    public static func next(_ step: Step) -> Step {
        Step(rawValue: min(step.rawValue + 1, Step.done.rawValue)) ?? .done
    }
    public static func back(_ step: Step) -> Step {
        Step(rawValue: max(step.rawValue - 1, 0)) ?? .welcome
    }

    public struct DownloadMetrics: Sendable {
        public let downloadedGB: Double
        public let totalGB: Double
        public let remainingGB: Double
        public let done: Bool
    }
    public static func downloadMetrics(
        progress: [SaymarkModelID: Double]
    ) -> DownloadMetrics {
        let downloaded = modelPlan.models.reduce(0) { total, model in
            let fraction = max(0, min(1, progress[model.id, default: 0]))
            return total + model.estimatedDownloadGB * fraction
        }
        let done = modelPlan.models.allSatisfy { progress[$0.id, default: 0] >= 1 }
        return DownloadMetrics(
            downloadedGB: downloaded,
            totalGB: totalGB,
            remainingGB: max(0, totalGB - downloaded),
            done: done
        )
    }
}
