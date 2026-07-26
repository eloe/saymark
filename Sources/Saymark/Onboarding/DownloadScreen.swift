import Foundation
import SaymarkKit
import SwiftUI

/// A single, user-facing preparation state. Model identities and internal roles
/// remain implementation details while the existing downloader reports real
/// progress and supports retry.
struct DownloadScreen: View {
    @Bindable var model: OnboardingModel

    private var metrics: OnboardingFlow.DownloadMetrics {
        OnboardingFlow.downloadMetrics(progress: model.flow.modelFractions)
    }

    private var fraction: Double {
        guard metrics.totalGB > 0 else { return 0 }
        return min(1, metrics.downloadedGB / metrics.totalGB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preparing on-device dictation")
                .font(.system(size: 26, weight: .semibold))

            Text("Saymark is downloading the language model it needs for private dictation.")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Dictation model download")
                    .accessibilityValue(metrics.done ? "Ready" : progressText)

                Text(metrics.done ? "Download complete" : progressText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Label("Stored on this Mac. Audio isn’t uploaded.", systemImage: "internaldrive")
                .font(.callout)
                .foregroundStyle(.secondary)

            if metrics.done {
                Label("Dictation is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let error = model.downloadError {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The download couldn’t be completed.")
                        .font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.retryDownload() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.startDownload() }
    }

    private var progressText: String {
        "Downloading \(String(format: "%.1f", metrics.downloadedGB)) GB of \(String(format: "%.1f", metrics.totalGB)) GB"
    }
}
