# Releasing Saymark

Saymark has two mutually exclusive binary release modes. The repository variable
`SAYMARK_TRUSTED_RELEASES` is unset by default, so `saymark-v*` tags build the
conspicuously untrusted artifact described below. Setting the variable to the
exact value `enabled` disables that job and enables the protected Apple-trusted
workflow instead.

## Current no-fee, untrusted release mode

This mode requires no Apple credentials and never references the protected
`release` environment. It exists so source-complete versions can be evaluated
before the owner enrolls in the Apple Developer Program.

The `Untrusted binary release` workflow enforces all of the following:

- every repository quality gate passes;
- the tag is an annotated full SemVer 2 tag reachable from `main`;
- the repository has zero open GitHub issues (pull requests do not count);
- the app is ad-hoc signed and has no Apple Team identifier or signing authority;
- the app uses `com.eloe.saymark.untrusted` and displays as
  `Saymark (Untrusted)`;
- the app has no stapled notarization ticket and fails Gatekeeper assessment;
- reviewed entitlements and bundled third-party notices remain present; and
- the ZIP, checksum, release title, release notes, and bundled warning all say
  that the binary is untrusted and not notarized.

Every untrusted binary is published as a GitHub prerelease even when its SemVer
has no prerelease component. Users must verify the attached SHA-256 checksum and
use macOS Privacy & Security to approve the specific app if they choose to run
it. Never disable Gatekeeper globally.

### Untrusted `1.0.0` checklist

1. Complete or explicitly decline every GitHub issue with a documented product
   decision; confirm there are zero open issues.
2. Merge only after unit, integration, performance, legal, dependency, secret,
   UI, and CodeQL gates pass.
3. Confirm the model revisions, exact byte sizes, and hashes in
   `SaymarkModelCatalog` match the accepted benchmark result.
4. Create the annotated tag `saymark-v1.0.0` at the verified `main` revision and
   push it once. Tag rules make this namespace immutable.
5. Wait for `Untrusted binary release` and the tag-triggered security scan.
6. Download the ZIP and checksum from GitHub on a separate account, verify the
   checksum, read `READ-ME-FIRST.txt`, and perform a clean onboarding,
   dictation, and insertion smoke test.
7. Record release-specific performance evidence and known limitations in the
   GitHub release notes.

Do not create the tag while any issue is open. The workflow independently checks
this condition and fails closed if the tag was created prematurely.

## Future Apple-trusted release mode

Only enable this mode after paid Apple Developer enrollment and the owner-gated
credential setup are complete.

1. Create the GitHub `release` environment.
2. Restrict it to protected branches and `saymark-v*` tags.
3. Require a reviewer where the repository plan permits it.
4. Populate all eight environment secrets listed in
   [`security-and-secrets.md`](security-and-secrets.md#future-release-secrets).
5. Set `SAYMARK_DEVELOPER_TEAM_ID` to the certificate's 10-character Team ID.
6. Set `SAYMARK_DEVELOPER_CERT_SHA256` to the leaf Developer ID certificate's
   SHA-256 fingerprint and independently verify the team owns
   `com.eloe.saymark`.
7. Set the repository variable `SAYMARK_TRUSTED_RELEASES` to exactly `enabled`.
8. Test the protected `Signed release` workflow before creating a production
   tag.

The signed workflow archives with Developer ID, enforces Hardened Runtime,
retains library validation, notarizes, staples, and passes Gatekeeper. It fails
if the certificate, Team ID, signature, entitlements, notarization, or assessment
differs from protected expectations. Never place those credentials in repository
secrets, workflow files, local `.env` files, or build configuration files.

Switching modes is a release-policy change. Review the workflows and repository
variable together; never permit trusted and untrusted publication jobs for the
same tag.

## Version contract

Release tags accept the complete
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) grammar,
including prerelease identifiers and build metadata. Numeric identifiers reject
leading zeroes.

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
and must include migration notes.

Build metadata does not affect precedence. A published tag and its artifacts are
immutable: never delete, recreate, or force-move a `saymark-v*` tag; publish a
new version for every change. Repository tag rules enforce deletion and
non-fast-forward protection for this namespace.
