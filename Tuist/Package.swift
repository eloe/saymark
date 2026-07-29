// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(productTypes: [:])
#endif

// Security manifest for app-only packages.
//
// The app continues to use Tuist's Xcode-native package integration declared
// in Project.swift. Keeping the same exact requirements here gives Tuist a
// standard, committed Package.resolved that GitHub's dependency graph and
// Dependabot can discover. `make dependency-check` prevents the declarations
// from drifting.
let package = Package(
    name: "SaymarkAppDependencies",
    dependencies: [
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts",
            exact: "3.0.1"
        ),
        .package(
            url: "https://github.com/PostHog/posthog-ios",
            exact: "3.68.4"
        ),
    ]
)
