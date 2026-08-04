# Security and secret management

Saymark's repository is public. Treat every committed byte, every Git ref, and
every GitHub Actions log as public information.

## Current secret inventory

Source builds, local builds, ordinary CI, and the explicitly untrusted binary
release require **no repository, Actions, Dependabot, Codespaces, or environment
secrets**. Apple-trusted distribution requires the protected `release`
environment secrets documented below.

- Local builds are ad-hoc signed, then signed with a self-generated
  `Saymark Local Development` identity stored only in the developer's local
  `saymark-local-signing.keychain-db`.
- The local signing script creates private material in a temporary directory,
  imports it into that local keychain, and removes the temporary directory when
  the script exits. The keychain has a random password stored as a generic
  password in the user's macOS login Keychain; no plaintext password file exists.
- Default source and local builds embed an empty PostHog project token. Remote
  telemetry is not initialized unless a maintainer deliberately injects a token.
- GitHub workflows use GitHub's automatic, short-lived `GITHUB_TOKEN`; no personal
  access token is stored in the repository.

The inherited Git history contains a Murmur Sparkle `SUPublicEDKey`. It is a
public update-verification key, not a private signing key or credential. Its exact
Gitleaks fingerprint is reviewed in `.gitleaksignore`; no broader rule is disabled.

## Never commit

- Developer ID or Apple Distribution private keys
- `.p12`, `.pfx`, PEM private keys, certificates, provisioning profiles, or
  keychain databases
- Apple notarization private keys
- Personal access tokens, API keys, passwords, or `.env` files
- Production telemetry tokens or crash-reporting credentials
- Real user audio, transcripts, clipboard data, or diagnostic bundles containing
  personal information

The repository `.gitignore`, `Scripts/security-audit.sh`, Gitleaks workflow,
GitHub secret scanning, and push protection form multiple independent controls.

## No-fee untrusted binary boundary

With `SAYMARK_TRUSTED_RELEASES` unset, `.github/workflows/untrusted-release.yml`
publishes only an ad-hoc-signed, non-notarized prerelease after every quality gate
passes and every GitHub issue is closed. That workflow must never declare the
`release` environment or reference Apple secrets. Its verification rejects an
Apple Team identifier, certificate authority, stapled ticket, successful
Gatekeeper assessment, production bundle identifier, or missing visible warning.

The distinct `com.eloe.saymark.untrusted` identity prevents this artifact from
masquerading as or silently replacing a future trusted build. A SHA-256 checksum
detects download corruption but does not confer publisher identity or Apple
trust.

## Future release secrets

Apple-trusted distribution uses the protected GitHub Environment named `release`.
Store release material only as environment secrets, restrict the environment
to protected branches and `saymark-v*` tags, and require approval before
deployment. Set the repository variable `SAYMARK_TRUSTED_RELEASES=enabled` only
after all credentials and protections are ready. The app target attaches its
reviewed entitlements and enables Hardened Runtime;
`.github/workflows/release.yml` notarizes, staples, verifies, and
Gatekeeper-assesses an artifact before publication. See
[`releasing.md`](releasing.md). The owner-supplied credentials remain tracked in
[`#2`](https://github.com/eloe/saymark/issues/2).
Expected names are:

| Secret | Purpose |
| --- | --- |
| `SAYMARK_DEVELOPER_ID_APPLICATION_P12` | Base64-encoded Developer ID Application identity |
| `SAYMARK_DEVELOPER_ID_APPLICATION_PASSWORD` | Password protecting the imported PKCS#12 |
| `SAYMARK_DEVELOPER_TEAM_ID` | Expected 10-character Apple Team ID |
| `SAYMARK_DEVELOPER_CERT_SHA256` | Expected leaf Developer ID certificate SHA-256 fingerprint |
| `SAYMARK_BUILD_KEYCHAIN_PASSWORD` | Ephemeral CI keychain password |
| `SAYMARK_NOTARY_KEY_ID` | App Store Connect API key identifier |
| `SAYMARK_NOTARY_ISSUER_ID` | App Store Connect issuer identifier |
| `SAYMARK_NOTARY_PRIVATE_KEY` | App Store Connect private key contents |

If remote analytics later passes every gate in `telemetry-todo.md`, store its
write-only project token as `SAYMARK_POSTHOG_PROJECT_TOKEN` and map it to
`TUIST_SAYMARK_POSTHOG_KEY` only for the approved release build step. Do not make
it a repository variable or place it in an `.xcconfig`.

Dependabot secrets are only for credentials required to fetch private package
registries. Saymark currently uses public packages and needs none.

`SaymarkKit`, app-only packages, and GitHub Actions have Dependabot coverage.
PostHog remains exact-version pinned in `Project.swift`. KeyboardShortcuts is an
exact-revision vendored package because Saymark carries a reviewed keyboard-focus
patch. `Vendor/KeyboardShortcuts/UPSTREAM.json` and
`UPSTREAM_RUNTIME.sha256` bind its upstream URL, version, revision, complete
runtime-file inventory, unchanged upstream bytes, and the allowlisted patched
file. `Tuist/Package.swift` keeps both upstream requirements visible and produces
the committed, GitHub-readable `Tuist/Package.resolved`. `make dependency-check`
fails if any declaration, revision, vendored runtime byte, or allowlisted patch
drifts.

GitHub does not reliably add nested Swift lockfiles to the repository SBOM by
static analysis alone. The `Dependency graph` workflow converts the committed
Tuist lockfile into GitHub's documented dependency-snapshot format on every
push to `main` and submits it with the workflow token's narrowly scoped
`contents: write` permission. No repository secret is required. The submitted
Swift package URLs make KeyboardShortcuts and PostHog visible to dependency
review and Dependabot alerts.

To update PostHog:

1. Change its exact version in both `Project.swift` and `Tuist/Package.swift`.
2. Run `make dependencies` to update the reviewed lockfile deterministically.
3. Run `make test-unit`, `make test-integration`, `make security-check`, and the
   relevant performance acceptance benchmark before merging.

To update KeyboardShortcuts, review the full old-upstream-to-new-upstream diff,
apply the smallest local patch to the new source, then update the exact version
and revision, regenerate `UPSTREAM_RUNTIME.sha256` from that revision, and record
only intentionally patched files and their before/after SHA-256 digests in
`UPSTREAM.json`. The same validation suite is required.

## Model supply-chain trust

Every production Hugging Face model is pinned to an immutable 40-character
commit in `SaymarkModelCatalog`. The reviewed catalog records every critical
file's exact byte size and SHA-256 digest. `PinnedModelStore` downloads that
revision, rejects a missing or unexpectedly sized file, hashes the critical
weights, configuration, and vocabulary, and only then moves the snapshot into
the directory that MLX loads. The first ensure in every app process rehashes each critical artifact;
the metadata manifest is an audit record and never an authorization shortcut.
That trust check costs one full multi-gigabyte read per model per process.
Repeated onboarding/load handoffs reuse only the actor-owned in-process
attestation; every restart pays the hash cost again. A mismatch removes the
untrusted cache and fails closed if a verified redownload is unavailable.

Model upgrades are source changes:

1. Review the upstream repository and select an immutable commit.
2. Download that exact revision and independently calculate SHA-256 for every
   critical runtime artifact.
3. Update the catalog revision, exact byte sizes, and hashes in one pull request.
4. Run unit, privacy, real-model accuracy, latency, CPU, and memory gates.
5. Record the model revision with the accepted benchmark result.

Explicit repository overrides remain available only to the CLI benchmark path
for candidate evaluation; shipped default models always use the pinned store.

## Required checks

Run before publishing:

```sh
make security-check
make legal-check
make architecture-check
```

GitHub additionally runs the full-history Gitleaks scan and tiered CodeQL Swift
analysis:

- Pull requests normally defer the traced Swift build and pass the required
  `CodeQL policy gate` in seconds. The fast repository-policy, dependency-review,
  test, and secrets checks remain blocking before merge.
- Add the `codeql-required` label when a security-sensitive pull request must run
  the default CodeQL suite before merge. Labeled drafts fail the policy gate
  until they are marked ready for review.
- Every merge to `main` runs the default CodeQL suite, so all merged Swift and
  build changes are analyzed without adding an hour to normal pull-request
  feedback.
- Release tags, the weekly schedule, and manual dispatches run the
  `security-extended` suite.

The required branch-protection context is `CodeQL policy gate`. Pull requests
receive that stable context from the fast policy job or, when labeled, from the
full macOS analysis job. Keep compiled `DerivedData` out of caches so a selected
CodeQL scan observes every compiler invocation.

## GitHub repository controls

The public repository should keep these enabled:

- Secret scanning
- Push protection
- Dependabot alerts and security updates
- Private vulnerability reporting
- CodeQL analysis

Protected `main` should require these app-bound checks:

- `Secrets and credential material`
- `CodeQL policy gate`
- `Quality policy gate`

`Quality policy gate` is the stable aggregate for CI configuration, repository
policy, Swift and app tests, deterministic UI integration tests, and pull-request
dependency review. Require only the aggregate rather than its internal jobs so
the branch rule stays correct when the matrix changes.

The repository currently has one administrator. Requiring an independent
approval would prevent that maintainer from merging any pull request, so review
count remains zero until a second trusted maintainer is added. At that point,
require one approval, dismiss stale approvals, require approval after the last
push, and add reviewed CODEOWNERS coverage for workflows, signing, entitlements,
and dependency manifests.

GitHub Actions policy should allow GitHub-owned actions plus the explicitly used
`jdx/mise-action` and `gitleaks/gitleaks-action`, and require every action to be
pinned to a full commit SHA. Default workflow token permissions remain read-only.

See [`SECURITY.md`](../SECURITY.md) for coordinated disclosure.
