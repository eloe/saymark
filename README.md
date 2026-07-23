# Saymark

> Speak naturally. Write anywhere.

Saymark is a native macOS voice-writing app. Hold a global shortcut, speak, and
Saymark inserts the finished text into the field you were already using.

The current development build runs transcription locally on Apple silicon. It
supports an efficient final-transcript mode and an optional live-preview mode
that uses a fast draft model while recording and a higher-accuracy model for the
final text.

## Status

Saymark is under active development and is not yet distributed as a signed or
notarized release. The local build uses a stable development-only signing
identity so macOS Accessibility approval survives rebuilds.

## Requirements

- macOS 15 or later
- Apple silicon
- Microphone permission
- Accessibility permission for automatic text insertion

## Build and install locally

The app uses Tuist, with the shared dictation core in `SaymarkKit/`.

```bash
make install-local
```

This builds Release configuration, signs it with Saymark's isolated local
identity, and installs it at `/Applications/Saymark.app`.

Useful commands:

```bash
make legal-check
make security-check
make architecture-check
make test-integration
make bench-accept-efficient WAV=/path/to/fixture.wav
make bench-accept-live WAV=/path/to/fixture.wav
make report-diagnostics
```

The [interactive architecture map](docs/architecture.html) and
[machine-readable agent handoff](docs/architecture.json) explain the complete
system. The [`docs/` index](docs/README.md) also covers local development,
automated testing, performance gates, diagnostics, and privacy/security.

## Architecture

- `Sources/Saymark/` — native macOS app and HUD
- `SaymarkKit/` — capture, VAD, model orchestration, transcription, and insertion
- `Tests/SaymarkTests/` — app and HUD tests
- `Tests/SaymarkUITests/` — XCUITest application flows
- `Benchmarks/` — performance acceptance fixtures and results
- `Branding/` — Saymark visual direction and icon exploration

## Origin and license

Saymark began as an independent continuation of the MIT-licensed
[Murmur](https://github.com/bshk-app/murmur) project by Aleksandr Beshkenadze.
The full Git history is retained. See [`CREDITS.md`](CREDITS.md) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Licensed under the MIT License. The original copyright and license notice are
preserved in [`LICENSE`](LICENSE).

Distributable builds include that notice and the dependency license texts in
[`ThirdPartyLicenses/`](ThirdPartyLicenses). Model weights are downloaded
separately and remain subject to the terms listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
