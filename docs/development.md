# Development

## Prerequisites

- macOS 15 or later on Apple silicon
- Xcode and its command-line tools
- Tuist
- Network access for the initial Swift-package and model downloads

Hosted CI pins Xcode 26.5 build 17F42 instead of following the runner image's
changing default. Local development may use another compatible Xcode 26 release;
set `DEVELOPER_DIR` when intentionally testing a non-default installation.

## Local app

```bash
make install-local
```

The first run creates an isolated, self-signed **Saymark Local Development**
identity. It cannot produce a notarized public release. The app is built in
Release configuration, signed consistently, installed at
`/Applications/Saymark.app`, and launched.

macOS will request Microphone and Accessibility permission for the new Saymark
identity once. Rebuilding with the same local identity should retain the grant.
Changing the bundle identifier, executable path, or signing identity can require
a new approval.

## Build without installing

```bash
make build
```

Release configuration is intentional: unoptimized MLX Swift builds do not
represent product latency.

## Dependencies

App-only packages use Tuist's Xcode-native integration in `Project.swift`.
Their exact requirements are mirrored in `Tuist/Package.swift` so GitHub can
index the committed `Tuist/Package.resolved`.

```bash
make dependencies
```

This resolves the committed versions and verifies that both manifests and the
lockfile agree. After an update, run unit and integration tests, the security
checks, and any performance benchmark affected by the dependency.

## Tests and benchmarks

```bash
cd SaymarkKit && swift test -c release
make test-integration
make bench-accept-efficient WAV=/path/to/fixture.wav
make bench-accept-live WAV=/path/to/fixture.wav
```

Hardware benchmarks are local acceptance gates, not generic hosted-CI tests.
Record the machine, OS, dependency versions, model revisions, and fixture with
every published result.

Pull requests run the core tests, app/HUD tests, and deterministic onboarding
and daily-driver UI tests. A single `Quality policy gate` reports failure unless
all applicable tests, repository checks, dependency review, and CI linters pass.
Swift and Xcode builds in hosted CI refuse to update committed package
resolutions automatically.

## Diagnostics

Local builds default to debug-level privacy-safe logging. See
[`diagnostic-logging.md`](diagnostic-logging.md) before changing instrumentation.
Never log audio, transcript text, selected text, or clipboard contents.
