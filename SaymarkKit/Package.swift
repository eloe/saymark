// swift-tools-version: 6.0
import PackageDescription

// Shared core for the Saymark menu-bar app and the saymark-cli tool: mic capture,
// the two-tier STT composition, the Silero speech gate, text injection, and the
// dictation orchestrator.
//
// STT + VAD come from the fork `beshkenadze/mlx-audio-swift` as a normal external
// dependency over HTTPS, pinned to the reviewed commit that carries the merged
// Nemotron streaming + Parakeet refinement + Silero VAD, all public, no dev-only
// tooling). The two-tier composition itself lives here in SaymarkKit, not the
// library — it's application policy (which models, how to merge, memory budget).
let package = Package(
    name: "SaymarkKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SaymarkKit", targets: ["SaymarkKit"]),
        .library(name: "LiveInsertionPolicy", targets: ["LiveInsertionPolicy"]),
        .executable(name: "saymark-cli", targets: ["saymark-cli"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/beshkenadze/mlx-audio-swift.git",
            revision: "6671490176d24bc962f0b8cd50dbf24e2427e387"
        ),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.31.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
    ],
    targets: [
        .target(name: "LiveInsertionPolicy"),
        .target(
            name: "SaymarkKit",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),   // Silero 32ms speech gate
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),  // ModelUtils.resolveOrDownloadModel
                .product(name: "HuggingFace", package: "swift-huggingface"), // Repo.ID / HubClient / HubCache
            ]
        ),
        .executableTarget(
            name: "saymark-cli",
            dependencies: [
                "SaymarkKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ]
        ),
        .testTarget(
            name: "SaymarkKitTests",
            dependencies: ["SaymarkKit"]
        ),
        .testTarget(
            name: "LiveInsertionPolicyTests",
            dependencies: ["LiveInsertionPolicy"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
