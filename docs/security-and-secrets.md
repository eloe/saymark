# Security and secret management

Saymark's repository is public. Treat every committed byte, every Git ref, and
every GitHub Actions log as public information.

## Current secret inventory

Saymark currently requires **no repository, Actions, Dependabot, Codespaces, or
environment secrets**.

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

## Future release secrets

When signed distribution begins, create a protected GitHub Environment named
`release`. Store release material only as environment secrets, restrict the
environment to `main` and version tags, and require approval before deployment.
Public binaries are blocked until the app target attaches its reviewed
entitlements, enables Hardened Runtime, and the release job notarizes, staples,
and verifies the artifact (tracked in
[`#2`](https://github.com/eloe/saymark/issues/2)).
Expected names are:

| Secret | Purpose |
| --- | --- |
| `SAYMARK_DEVELOPER_ID_APPLICATION_P12` | Base64-encoded Developer ID Application identity |
| `SAYMARK_DEVELOPER_ID_APPLICATION_PASSWORD` | Password protecting the imported PKCS#12 |
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

`SaymarkKit` dependencies and GitHub Actions have Dependabot coverage. The
app-only KeyboardShortcuts and PostHog packages are exact-version pinned in the
Tuist manifest, but are not yet represented by a committed GitHub-readable
lockfile; closing that dependency-graph gap is tracked in
[`#3`](https://github.com/eloe/saymark/issues/3).

## Known model supply-chain risk

The Swift package dependencies are locked to reviewed versions or commits.
Downloaded Hugging Face model repositories are not yet equivalently immutable:
the inherited MLX audio downloader resolves their `main` branch. A repository
owner could therefore change model weights without a Saymark source change.

Before a public release, Saymark must pin an immutable Hugging Face commit for
every shipped model, verify the downloaded snapshot and critical files against a
checked-in manifest, and make model upgrades an explicit reviewed change. Until
that work lands, model downloads should be treated as third-party executable
content rather than trusted release artifacts. This release blocker is tracked
in [`#1`](https://github.com/eloe/saymark/issues/1).

## Required checks

Run before publishing:

```sh
make security-check
make legal-check
make architecture-check
```

GitHub additionally runs the full-history Gitleaks scan and CodeQL Swift analysis.

## GitHub repository controls

The public repository should keep these enabled:

- Secret scanning
- Push protection
- Dependabot alerts and security updates
- Private vulnerability reporting
- CodeQL analysis

See [`SECURITY.md`](../SECURITY.md) for coordinated disclosure.
