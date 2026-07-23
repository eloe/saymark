# Security policy

## Supported versions

Saymark is pre-release software. Security fixes are applied to the latest commit
on `main`; older development builds and historical Murmur tags are not supported.

## Report a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's **Report a vulnerability** flow on the repository's Security page:

<https://github.com/eloe/saymark/security/advisories/new>

Include the affected commit or build, reproduction steps, impact, and any
suggested mitigation. Do not attach real user audio, transcripts, credentials,
private keys, or other sensitive personal data.

The maintainer will acknowledge a report as soon as practical, validate it,
coordinate a fix privately, and publish an advisory when users have a safe
upgrade path.

## Security boundaries

Audio and transcript text must remain on-device. Model artifacts may be
downloaded from their documented repositories. Automatic insertion uses macOS
Accessibility, and Saymark never attempts to bypass Secure Event Input.

See [`docs/security-and-secrets.md`](docs/security-and-secrets.md) and
[`docs/privacy-and-security.md`](docs/privacy-and-security.md).
