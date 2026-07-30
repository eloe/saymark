import Foundation
import ProjectDescription

// Tuist is the source of truth for the Saymark app target — it regenerates the
// .xcodeproj, so bundle id and signing MUST live here (Xcode edits get clobbered).
//
// The app is a thin UI over SaymarkKit, the shared dictation core it builds from
// the local `SaymarkKit/` Swift package (which pulls STT from an immutable
// reviewed fork revision). The same SaymarkKit powers `saymark-cli`. The global
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
                requirement: .exact("3.0.1")),
        .remote(url: "https://github.com/PostHog/posthog-ios",
                requirement: .exact("3.67.1")),   // future anonymous analytics; strictly opt-in
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
                "CFBundleIconName": "AppIcon",
                "CFBundleLocalizations": ["en", "ru"],
                "CFBundleDevelopmentRegion": "en",
                "NSMicrophoneUsageDescription":
                    "Saymark transcribes your speech on-device while you hold the dictation hotkey.",
                // Future Saymark-owned analytics key. Empty in source/local builds → no network telemetry.
                "PostHogAPIKey": .string(posthogAPIKey),
                // Workaround for KeyboardShortcuts 3.0.1 (latest): its Carbon hotkey
                // callback calls MainActor.assumeIsolated after a Thread.isMainThread
                // guard. Under the macOS 26 / Swift 6.2 runtime, being on the main
                // thread no longer implies the main-actor executor, so assumeIsolated
                // traps (EXC_BREAKPOINT) on every hotkey press. Restoring the legacy
                // isCurrentExecutor behavior avoids the trap until the dep is fixed.
                "LSEnvironment": .dictionary([
                    "SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE": .string("legacy"),
                ]),
            ]),
            sources: ["Sources/Saymark/**/*.swift"],
            resources: [
                "Sources/Saymark/Resources/**",
                "LICENSE",
                "THIRD_PARTY_NOTICES.md",
                "ThirdPartyLicenses/**",
            ],
            entitlements: .file(path: "Saymark.entitlements"),
            dependencies: [
                .package(product: "SaymarkKit"),
                .package(product: "KeyboardShortcuts"),
                .package(product: "PostHog"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                // Source builds are ad-hoc. The installer applies Saymark's stable
                // local identity so the Accessibility grant persists across builds.
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "-",
                // Developer ID notarization requires Hardened Runtime. The
                // isolated local identity disables it so hosted XCTest bundles
                // with a different ad-hoc Team ID can load; release CI overrides YES.
                "ENABLE_HARDENED_RUNTIME": isLocalBuild ? "NO" : "YES",
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
