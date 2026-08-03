# Releasing Saymark

Public binaries must come only from the protected `Signed release` workflow.
Local and pull-request builds are intentionally non-distribution builds.

## One-time owner setup

1. Create the GitHub `release` environment.
2. Restrict it to protected branches and `saymark-v*` tags.
3. Require a reviewer where the repository plan permits it.
4. Populate the eight environment secrets listed in
   [`security-and-secrets.md`](security-and-secrets.md#future-release-secrets).
5. Set `SAYMARK_DEVELOPER_TEAM_ID` to the certificate's 10-character Team ID.
6. Set `SAYMARK_DEVELOPER_CERT_SHA256` to the leaf Developer ID certificate's
   SHA-256 fingerprint. Obtain it from a trusted local certificate copy with
   `openssl x509 -in certificate.pem -noout -fingerprint -sha256`.
7. Confirm the certificate and Team ID belong to the team that owns
   `com.eloe.saymark`; independently compare the protected values before approval.

Environment secrets are unavailable to the job until the environment's
protection rules pass. Never place release credentials in repository secrets,
workflow files, local `.env` files, or build configuration files.

## Release checklist

1. Merge only after unit, integration, performance, legal, dependency, secret,
   and CodeQL gates pass.
2. Confirm the model revisions, exact byte sizes, and hashes in
   `SaymarkModelCatalog` match the accepted benchmark result.
3. Create an annotated `saymark-v<SemVer>` tag from protected `main` and push it,
   for example `saymark-v0.2.0`, `saymark-v0.2.0-rc.1`, or
   `saymark-v0.2.0-rc.1+build.7`.
4. Review and approve the `release` environment deployment.
5. The workflow must archive with Developer ID, enforce Hardened Runtime,
   retain library validation, notarize, staple, and pass Gatekeeper assessment.
6. Download the published ZIP and checksum from a separate Mac account, verify
   the checksum, and perform a clean onboarding/dictation/insertion smoke test
   in both Hold to Dictate and Press to Start/Stop modes. Confirm that
   Start/Stop shows the active-display halo and that Reduce Motion suppresses
   its bloom.
7. Record any release-specific performance result or known limitation in the
   GitHub release notes.

The release workflow fails before publication if the imported certificate or
signed app differs from the protected Team ID or certificate SHA-256, if the app
is ad-hoc signed, missing its microphone entitlement, lacks Hardened Runtime,
disables library validation, lacks a stapled ticket, or fails Gatekeeper.

## Version contract

Release tags accept the complete
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) grammar,
including prerelease identifiers and build metadata. Numeric identifiers reject
leading zeroes. Tags containing a prerelease component publish a GitHub
prerelease automatically.

Apple requires `CFBundleShortVersionString` to be a numeric `X.Y.Z`, so the app
stores the SemVer core there and the complete release identity in the
`SaymarkSemanticVersion` Info.plist key. `CFBundleVersion` remains the monotonic
GitHub Actions run number. Artifact names and GitHub releases retain the complete
SemVer string.

Saymark's declared public compatibility surface is:

- documented `saymark-cli` arguments, exit behavior, and machine-consumed output;
- versioned import/export formats and their forward/backward-compatibility rules;
- persisted user-data schemas and documented migration guarantees; and
- documented integration contracts intended for use outside the app target.

Internal Swift APIs, undocumented diagnostics, visual details, and experimental
features are not public API. A patch release contains only backward-compatible
fixes to the declared surface. A minor release may add backward-compatible
capabilities or schema fields. A major release may make an incompatible change
and must include migration notes. While the major version is zero, Saymark is in
initial development as defined by SemVer 2.0.0, but incompatible changes must
still be called out in release notes.

Build metadata does not affect precedence. A published tag and its artifacts are
immutable: never delete, recreate, or force-move a `saymark-v*` tag; publish a
new version for every change. Repository tag rules enforce deletion and
non-fast-forward protection for this namespace.
