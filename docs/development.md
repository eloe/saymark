# Development

## Prerequisites

- macOS 15 or later on Apple silicon
- Xcode and its command-line tools
- Tuist
- Network access for the initial Swift-package and model downloads

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

## Diagnostics

Local builds default to debug-level privacy-safe logging. See
[`diagnostic-logging.md`](diagnostic-logging.md) before changing instrumentation.
Never log audio, transcript text, selected text, or clipboard contents.
