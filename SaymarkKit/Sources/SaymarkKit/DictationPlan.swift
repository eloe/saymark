import Foundation

/// Stable model identities used by runtime policy, onboarding, and benchmarks.
/// Users choose a dictation experience; they do not assemble model graphs.
public enum SaymarkModelID: String, CaseIterable, Hashable, Sendable {
    case nemotron
    case parakeet
}

public enum SaymarkModelRole: String, Sendable {
    case streamingDraft
    case offlineFinal
}

public struct SaymarkModelDescriptor: Equatable, Identifiable, Sendable {
    public let id: SaymarkModelID
    public let repository: String
    public let estimatedDownloadGB: Double
    public let role: SaymarkModelRole

    public init(
        id: SaymarkModelID,
        repository: String,
        estimatedDownloadGB: Double,
        role: SaymarkModelRole
    ) {
        self.id = id
        self.repository = repository
        self.estimatedDownloadGB = estimatedDownloadGB
        self.role = role
    }
}

public enum SaymarkModelCatalog {
    public static let nemotron = SaymarkModelDescriptor(
        id: .nemotron,
        repository: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
        estimatedDownloadGB: 0.6,
        role: .streamingDraft
    )

    public static let parakeet = SaymarkModelDescriptor(
        id: .parakeet,
        repository: "mlx-community/parakeet-tdt-0.6b-v3",
        estimatedDownloadGB: 2.5,
        role: .offlineFinal
    )
}

/// The two product-level choices. Model composition remains an implementation
/// detail so a user cannot accidentally select an unsupported or costly pair.
public enum DictationExperience: String, CaseIterable, Sendable {
    case efficient
    case livePreview

    public var mode: DictationMode {
        switch self {
        case .efficient: return .accurate
        case .livePreview: return .hybrid
        }
    }
}

/// A single source of truth for the models and interaction semantics of a mode.
/// `.fast` remains available to benchmarks and diagnostics, but is not exposed as
/// a normal `DictationExperience`.
public struct DictationPlan: Equatable, Sendable {
    public let mode: DictationMode
    public let models: [SaymarkModelDescriptor]
    public let finalModelID: SaymarkModelID
    public let providesLivePreview: Bool

    public var finalModel: SaymarkModelDescriptor {
        guard let model = models.first(where: { $0.id == finalModelID }) else {
            preconditionFailure("DictationPlan final model must be present in models")
        }
        return model
    }

    public var estimatedDownloadGB: Double {
        models.reduce(0) { $0 + $1.estimatedDownloadGB }
    }

    public static func forExperience(_ experience: DictationExperience) -> Self {
        forMode(experience.mode)
    }

    public static func forMode(_ mode: DictationMode) -> Self {
        switch mode {
        case .fast:
            return Self(
                mode: mode,
                models: [SaymarkModelCatalog.nemotron],
                finalModelID: .nemotron,
                providesLivePreview: true
            )
        case .hybrid:
            return Self(
                mode: mode,
                models: [SaymarkModelCatalog.nemotron, SaymarkModelCatalog.parakeet],
                finalModelID: .parakeet,
                providesLivePreview: true
            )
        case .accurate:
            return Self(
                mode: mode,
                models: [SaymarkModelCatalog.parakeet],
                finalModelID: .parakeet,
                providesLivePreview: false
            )
        }
    }
}
