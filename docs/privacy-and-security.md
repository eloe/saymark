# Privacy and security

Saymark's transcription path is local-first. Audio capture and transcript text
are sensitive data and must remain outside logs and telemetry.

## Data handling

- Microphone audio is consumed for the active dictation session.
- Audio and transcript text are not written to diagnostic logs.
- Models are downloaded from their documented repositories and cached locally.
- Automatic text insertion uses macOS Accessibility permission.
- Without Accessibility permission, Saymark can still copy or display text but
  cannot type into another application automatically.

## Diagnostics

Diagnostics may contain timings, numeric resource measurements, model repository
identifiers, app/OS versions, error categories, and randomized session IDs.
They must not contain audio samples, transcript text, focused-field contents,
selected text, or clipboard contents. See [`diagnostic-logging.md`](diagnostic-logging.md).

Current source and local builds do not send usage or crash reports. Their
diagnostics remain in a local file. Remote telemetry must remain disabled until
the requirements in [`telemetry-todo.md`](telemetry-todo.md) are complete.

## Local development identity

The self-signed local identity exists only to stabilize macOS trust during
development. It is not a substitute for Developer ID signing, notarization, or a
public release process. Never distribute builds signed with that identity as an
official release.

## Reporting vulnerabilities

Until a public security contact is configured, avoid publishing exploit details
in a public issue. Repository maintainers should add a private GitHub security
advisory workflow before the first public binary release.
