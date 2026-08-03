#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: verify-untrusted-release-app.sh /path/to/Saymark.app --semver VERSION}"
shift
expected_semver=""
while (($#)); do
  case "$1" in
    --semver) expected_semver="${2:?missing semantic version}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$expected_semver" ]] || { echo "Expected semantic version is required" >&2; exit 2; }
[[ -d "$app" ]] || { echo "Untrusted release app not found: $app" >&2; exit 1; }

signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
grep -q '^Signature=adhoc$' <<<"$signature" ||
  { echo "Untrusted release must use only an ad-hoc signature" >&2; exit 1; }
if grep -q '^Authority=' <<<"$signature"; then
  echo "Untrusted release unexpectedly contains a certificate authority" >&2
  exit 1
fi
grep -q '^TeamIdentifier=not set$' <<<"$signature" ||
  { echo "Untrusted release unexpectedly has an Apple Team identifier" >&2; exit 1; }
grep -q '^Identifier=com\.eloe\.saymark\.untrusted$' <<<"$signature" ||
  { echo "Unexpected untrusted release bundle identifier" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$app"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
semantic_version="$(/usr/libexec/PlistBuddy -c 'Print :SaymarkSemanticVersion' "$app/Contents/Info.plist")"
display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist")"
[[ "$bundle_id" == "com.eloe.saymark.untrusted" ]] ||
  { echo "Unexpected bundle identifier: $bundle_id" >&2; exit 1; }
[[ "$semantic_version" == "$expected_semver" ]] ||
  { echo "Semantic version does not match release tag" >&2; exit 1; }
[[ "$display_name" == "Saymark (Untrusted)" ]] ||
  { echo "Untrusted status is not visible in the app display name" >&2; exit 1; }

entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
grep -q 'com.apple.security.device.audio-input' <<<"$entitlements" ||
  { echo "Untrusted release is missing the microphone entitlement" >&2; exit 1; }
if grep -q 'com.apple.security.cs.disable-library-validation' <<<"$entitlements"; then
  echo "Untrusted release unexpectedly disables library validation" >&2
  exit 1
fi

if xcrun stapler validate "$app" >/dev/null 2>&1; then
  echo "Untrusted release unexpectedly has a stapled notarization ticket" >&2
  exit 1
fi
if spctl --assess --type execute "$app" >/dev/null 2>&1; then
  echo "Untrusted release unexpectedly passes Gatekeeper assessment" >&2
  exit 1
fi

echo "Verified conspicuously untrusted, ad-hoc signed, non-notarized app: $app"
