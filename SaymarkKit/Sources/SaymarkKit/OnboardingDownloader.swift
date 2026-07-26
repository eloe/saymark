import Foundation

/// Downloads a plan's model repos up front with live per-model progress, into the
/// Hugging Face cache that `*.fromPretrained` later reads (so loading does not
/// re-download). Repositories are pinned to immutable commits and critical files
/// are verified before the runtime can load them.
public actor OnboardingDownloader {
    /// Per-model download fractions (0…1), reported together each tick.
    public struct Progress: Sendable {
        public var fractions: [SaymarkModelID: Double] = [:]
        public init() {}
    }

    /// Running per-model state, mutated only on this actor and snapshotted out to
    /// the main-actor callback — no captured-`var` data race.
    private var progress = Progress()
    private let onProgress: @MainActor @Sendable (Progress) -> Void

    private init(onProgress: @escaping @MainActor @Sendable (Progress) -> Void) {
        self.onProgress = onProgress
    }

    /// Download both repos sequentially, reporting `(fast, accurate)` fractions on
    /// the main actor after every progress tick.
    public static func download(
        plan: DictationPlan = OnboardingFlow.modelPlan,
        onProgress: @escaping @MainActor @Sendable (Progress) -> Void
    ) async throws {
        try await OnboardingDownloader(onProgress: onProgress).run(plan: plan)
    }

    private func run(plan: DictationPlan) async throws {
        // VAD is small and shared by every mode. Verify it before progress can
        // reach 100%, so onboarding never declares an incomplete trust set ready.
        _ = try await PinnedModelStore.shared.ensure(SaymarkModelCatalog.silero)
        for model in plan.models {
            try await fetch(model.artifactSet) { [weak self] fraction in
                await self?.set(fraction, for: model.id)
            }
        }
    }

    private func set(_ fraction: Double, for modelID: SaymarkModelID) {
        progress.fractions[modelID] = fraction
        let snap = progress
        Task { @MainActor in onProgress(snap) }
    }

    /// Resolve-or-download one repo into the shared cache, forwarding the
    /// Foundation `Progress.fractionCompleted` (0…1) on each tick.
    private func fetch(
        _ descriptor: PinnedModelArtifactSet,
        _ onFraction: @escaping @Sendable (Double) async -> Void
    ) async throws {
        _ = try await PinnedModelStore.shared.ensure(
            descriptor,
            progressHandler: { progress in
                Task { await onFraction(progress.fractionCompleted) }   // 0…1
            }
        )
        await onFraction(1.0)   // mark complete (cache hit returns without a tick)
    }
}
