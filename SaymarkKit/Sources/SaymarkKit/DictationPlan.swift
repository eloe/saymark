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

public struct PinnedModelArtifact: Codable, Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let sha256: String

    public init(path: String, size: UInt64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

public struct PinnedModelArtifactSet: Codable, Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let artifacts: [PinnedModelArtifact]

    public init(repository: String, revision: String, artifacts: [PinnedModelArtifact]) {
        self.repository = repository
        self.revision = revision
        self.artifacts = artifacts
    }
}

public struct SaymarkModelDescriptor: Equatable, Identifiable, Sendable {
    public let id: SaymarkModelID
    public let estimatedDownloadGB: Double
    public let role: SaymarkModelRole
    public let artifactSet: PinnedModelArtifactSet

    public var repository: String { artifactSet.repository }

    public init(
        id: SaymarkModelID,
        repository: String,
        revision: String,
        artifacts: [PinnedModelArtifact],
        estimatedDownloadGB: Double,
        role: SaymarkModelRole
    ) {
        self.id = id
        self.estimatedDownloadGB = estimatedDownloadGB
        self.role = role
        self.artifactSet = PinnedModelArtifactSet(
            repository: repository,
            revision: revision,
            artifacts: artifacts
        )
    }
}

public enum SaymarkModelCatalog {
    public static let nemotron = SaymarkModelDescriptor(
        id: .nemotron,
        repository: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
        revision: "7279359e4481b5e9e185a318bd618e429c6d86cd",
        artifacts: [
            .init(path: "model.safetensors", size: 755_598_923, sha256: "a64a4da048e7d28dde4cd4ff61ce59308a63314bb5563e73e06c24aae50ea941"),
            .init(path: "config.json", size: 159_605, sha256: "f30c7bc469fc01fd5483172b4d7c75075030ddb60f347589c44e216b0a5ea9b6"),
            .init(path: "vocab.txt", size: 78_294, sha256: "d74b60edd1cad792cfce25dcb7e1048d78d717cf4f29acaae2854262d5189f4f"),
        ],
        estimatedDownloadGB: 0.6,
        role: .streamingDraft
    )

    public static let parakeet = SaymarkModelDescriptor(
        id: .parakeet,
        repository: "mlx-community/parakeet-tdt-0.6b-v3",
        revision: "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15",
        artifacts: [
            .init(path: "model.safetensors", size: 2_508_288_736, sha256: "05e01c7f396c298cf7d23f61da7b504adeab698f0aaeafd9c82d198625464592"),
            .init(path: "config.json", size: 244_093, sha256: "f320f1292511f34ec47f513755fe20fd01dbfc09a925d42730e66059a6e1ef4c"),
            .init(path: "vocab.txt", size: 46_772, sha256: "3cde1409fd78783a79b29ed4d32da57c746993856f7c8263bcb905d2e5839db7"),
        ],
        estimatedDownloadGB: 2.5,
        role: .offlineFinal
    )

    public static let silero = PinnedModelArtifactSet(
        repository: "mlx-community/silero-vad",
        revision: "7bc17f22d3c0451bd3a6cd71e759b009271ff49a",
        artifacts: [
            .init(path: "model.safetensors", size: 2_179_454, sha256: "185e0bc3ee2c48ce425a37209fe917a1aca22ab6b85799430dd1b4894087a8b8"),
            .init(path: "config.json", size: 549, sha256: "f411ebae77d635372a636645fca4a4bb574b2da73e49b21bfef9685ae90e31bc"),
        ]
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
