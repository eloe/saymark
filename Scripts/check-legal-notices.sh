#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
resolved="$repo_root/.package.resolved"
licenses="$repo_root/ThirdPartyLicenses"
app_path=${1:-}

fail() {
  echo "legal-notices: $*" >&2
  exit 1
}

[[ -f "$repo_root/LICENSE" ]] || fail "missing LICENSE"
grep -Fq 'Copyright (c) 2026 Aleksandr Beshkenadze' "$repo_root/LICENSE" \
  || fail "the original Murmur copyright notice is missing"
grep -Fq 'MIT License' "$repo_root/LICENSE" || fail "the MIT license text is missing"
[[ -f "$repo_root/THIRD_PARTY_NOTICES.md" ]] || fail "missing THIRD_PARTY_NOTICES.md"
[[ -f "$resolved" ]] || fail "missing .package.resolved"
[[ -d "$licenses" ]] || fail "missing ThirdPartyLicenses directory"

missing=0
while IFS= read -r identity; do
  if ! find "$licenses" -maxdepth 1 -type f -name "${identity}--*" -print -quit \
    | grep -q .; then
    echo "legal-notices: no checked-in license or notice for $identity" >&2
    missing=1
  fi
done < <(sed -n 's/.*"identity" : "\([^"]*\)".*/\1/p' "$resolved" | sort -u)

[[ "$missing" -eq 0 ]] || exit 1

for required in \
  'posthog-ios--vendor--PHPLCrashReporter--LICENSE' \
  'posthog-ios--vendor--libwebp--COPYING' \
  'mlx-swift--Source--Cmlx--metal-cpp--LICENSE.txt' \
  'mlx-swift--Source--Cmlx--fmt--LICENSE' \
  'mlx-swift--Source--Cmlx--json--LICENSE.MIT'
do
  [[ -f "$licenses/$required" ]] || fail "missing bundled-component notice: $required"
done

if [[ -n "$app_path" ]]; then
  resources="$app_path/Contents/Resources"
  [[ -d "$resources" ]] || fail "application resources not found: $resources"
  [[ -f "$resources/LICENSE" ]] || fail "application bundle is missing LICENSE"
  [[ -f "$resources/THIRD_PARTY_NOTICES.md" ]] \
    || fail "application bundle is missing THIRD_PARTY_NOTICES.md"

  while IFS= read -r identity; do
    find "$resources" -maxdepth 1 -type f -name "${identity}--*" -print -quit \
      | grep -q . || fail "application bundle is missing the $identity notice"
  done < <(sed -n 's/.*"identity" : "\([^"]*\)".*/\1/p' "$resolved" | sort -u)
fi

echo "legal-notices: PASS"
