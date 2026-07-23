import Foundation
import ProjectDescription

// Tuist is the source of truth for the Saymark app target — it regenerates the
// .xcodeproj, so bundle id and signing MUST live here (Xcode edits get clobbered).
//
// The app is a thin UI over SaymarkKit, the shared dictation core it builds from
// the local `SaymarkKit/` Swift package (which pulls STT from the fork's
// `dev/nemo-mic` worktree). The same SaymarkKit powers `saymark-cli`. The global
// hotkey uses Carbon `RegisterEventHotKey` (KeyboardShortcuts) — no Accessibility.

// PostHog ingestion key injected at generation time. Tuist only forwards TUIST_-prefixed env
// vars into the manifest, so the maintainer's build sets TUIST_SAYMARK_POSTHOG_KEY (local or
// CI). Absent in a plain `tuist generate` → source/fork builds ship with analytics OFF.
let posthogAPIKey = ProcessInfo.processInfo.environment["TUIST_SAYMARK_POSTHOG_KEY"] ?? ""

// App version comes from the release tag. Tuist ONLY forwards TUIST_-prefixed env vars into
// the manifest, so CI must export TUIST_APP_VERSION (`saymark-vX.Y.Z` → X.Y.Z) before
// `tuist generate` — a bare APP_VERSION is silently filtered out and the build falls back.
// TUIST_APP_BUILD (e.g. the run number) gives a monotonic CFBundleVersion; else the version.
// Without these, Tuist's default Info.plist ships the placeholder 1.0.
let appVersion = ProcessInfo.processInfo.environment["TUIST_APP_VERSION"] ?? "0.1.0"
let appBuild = ProcessInfo.processInfo.environment["TUIST_APP_BUILD"] ?? appVersion
let isLocalBuild = ProcessInfo.processInfo.environment["TUIST_SAYMARK_LOCAL_BUILD"] == "1"
let appBundleID = isLocalBuild ? "com.eloe.saymark.local" : "com.eloe.saymark"
let appDisplayName = "Saymark"

let project = Project(
    name: "Saymark",
    packages: [
        .local(path: "SaymarkKit"),
        .remote(url: "https://github.com/sindresorhus/KeyboardShortcuts",
                requirement: .exact("2.4.0")),
        .remote(url: "https://github.com/PostHog/posthog-ios",
                requirement: .exact("3.66.1")),   // future anonymous analytics; strictly opt-in
    ],
    targets: [
        .target(
            name: "Saymark",
            destinations: .macOS,
            product: .app,
            bundleId: appBundleID,
            deploymentTargets: .macOS("15.0"),   // MLXAudioSTT (dev/nemo-mic) requires macOS 15
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": .string(appVersion),   // X.Y.Z from the release tag
                "CFBundleVersion": .string(appBuild),                // monotonic build (APP_BUILD) or version
                "LSUIElement": true,                       // menu-bar agent: no Dock icon
                "LSApplicationCategoryType": "public.app-category.productivity",
                "CFBundleDisplayName": .string(appDisplayName),
                "CFBundleName": .string(appDisplayName),
                "CFBundleLocalizations": ["en", "ru"],
                "CFBundleDevelopmentRegion": "en",
                "NSMicrophoneUsageDescription":
                    "Saymark transcribes your speech on-device while you hold the dictation hotkey.",
                // Future Saymark-owned analytics key. Empty in source/local builds → no network telemetry.
                "PostHogAPIKey": .string(posthogAPIKey),
            ]),
            sources: ["Sources/Saymark/**/*.swift"],
            resources: [
                "Sources/Saymark/Resources/**",
                "LICENSE",
                "THIRD_PARTY_NOTICES.md",
                "ThirdPartyLicenses/**",
            ],
            dependencies: [
                .package(product: "SaymarkKit"),
                .package(product: "KeyboardShortcuts"),
                .package(product: "PostHog"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
                // Source builds are ad-hoc. The installer applies Saymark's stable
                // local identity so the Accessibility grant persists across builds.
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "-",
            ])
        ),
        .target(
            name: "SaymarkTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.eloe.saymark.tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/SaymarkTests/**/*.swift"],
            dependencies: [.target(name: "Saymark")],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
            ])
        ),
        .target(
            name: "SaymarkUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "com.eloe.saymark.uitests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/SaymarkUITests/**/*.swift"],
            dependencies: [.target(name: "Saymark")],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
            ])
        ),
    ]
)
