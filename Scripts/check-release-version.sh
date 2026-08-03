#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
parser="$repo_root/Scripts/release-version.sh"
checks=0

expect_valid() {
  local tag="$1"
  local expected_semver="$2"
  local expected_core="$3"
  local expected_prerelease="$4"

  [[ "$("$parser" semver "$tag")" == "$expected_semver" ]]
  [[ "$("$parser" core "$tag")" == "$expected_core" ]]
  [[ "$("$parser" prerelease "$tag")" == "$expected_prerelease" ]]
  ((checks += 1))
}

expect_invalid() {
  local tag="$1"

  if "$parser" semver "$tag" >/dev/null 2>&1; then
    printf 'release-version-check: invalid tag was accepted: %s\n' "$tag" >&2
    exit 1
  fi
  ((checks += 1))
}

expect_valid saymark-v0.0.0 0.0.0 0.0.0 false
expect_valid saymark-v1.2.3 1.2.3 1.2.3 false
expect_valid saymark-v1.2.3-alpha 1.2.3-alpha 1.2.3 true
expect_valid saymark-v1.2.3-alpha.1 1.2.3-alpha.1 1.2.3 true
expect_valid saymark-v1.2.3-0A-1 1.2.3-0A-1 1.2.3 true
expect_valid saymark-v1.2.3+build.001 1.2.3+build.001 1.2.3 false
expect_valid saymark-v1.2.3-rc.1+build.7 1.2.3-rc.1+build.7 1.2.3 true

expect_invalid saymark-v1
expect_invalid saymark-v1.2
expect_invalid saymark-v01.2.3
expect_invalid saymark-v1.02.3
expect_invalid saymark-v1.2.03
expect_invalid saymark-v1.2.3-01
expect_invalid saymark-v1.2.3-
expect_invalid saymark-v1.2.3-alpha..1
expect_invalid saymark-v1.2.3-alpha_beta
expect_invalid saymark-v1.2.3+
expect_invalid saymark-v1.2.3+build..1
expect_invalid v1.2.3

printf 'release-version-check: PASS (%d tags)\n' "$checks"
