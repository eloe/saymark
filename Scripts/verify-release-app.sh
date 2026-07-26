#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: verify-release-app.sh /path/to/Saymark.app --team-id TEAMID --cert-sha256 SHA256 [--notarized]}"
shift
expected_team_id=""
expected_cert_sha256=""
notarized=false
while (($#)); do
  case "$1" in
    --team-id) expected_team_id="${2:?missing Team ID}"; shift 2 ;;
    --cert-sha256) expected_cert_sha256="${2:?missing certificate SHA-256}"; shift 2 ;;
    --notarized) notarized=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]] ||
  { echo "Expected Team ID is required" >&2; exit 2; }
expected_cert_sha256="$(tr -d ':' <<<"$expected_cert_sha256" | tr '[:lower:]' '[:upper:]')"
[[ "$expected_cert_sha256" =~ ^[A-F0-9]{64}$ ]] ||
  { echo "Expected certificate SHA-256 is required" >&2; exit 2; }

[[ -d "$app" ]] || { echo "Release app not found: $app" >&2; exit 1; }

signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
grep -q 'Authority=Developer ID Application:' <<<"$signature" ||
  { echo "Release app is not signed with Developer ID Application" >&2; exit 1; }
grep -q "TeamIdentifier=$expected_team_id" <<<"$signature" ||
  { echo "Release app signing team does not match expected Team ID" >&2; exit 1; }
grep -q 'runtime' <<<"$signature" ||
  { echo "Release app does not enable Hardened Runtime" >&2; exit 1; }
grep -q 'Identifier=com\.eloe\.saymark' <<<"$signature" ||
  { echo "Unexpected release bundle identifier" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$app"

certificate_directory="$(mktemp -d "$TMPDIR/saymark-release-cert.XXXXXX")"
certificate_prefix="$certificate_directory/cert"
trap 'rm -rf "$certificate_directory"' EXIT
codesign -d --extract-certificates "$certificate_prefix" "$app"
actual_cert_sha256="$(shasum -a 256 "${certificate_prefix}0" | awk '{print toupper($1)}')"
[[ "$actual_cert_sha256" == "$expected_cert_sha256" ]] ||
  { echo "Release app certificate does not match expected SHA-256 fingerprint" >&2; exit 1; }

entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
grep -q 'com.apple.security.device.audio-input' <<<"$entitlements" ||
  { echo "Release app is missing the microphone entitlement" >&2; exit 1; }
if grep -q 'com.apple.security.cs.disable-library-validation' <<<"$entitlements"; then
  echo "Release app unexpectedly disables library validation" >&2
  exit 1
fi

if [[ "$notarized" == true ]]; then
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi
