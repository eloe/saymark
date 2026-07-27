#!/usr/bin/env bash
set -euo pipefail

expected_version="${1:?usage: check-xcode-version.sh VERSION BUILD}"
expected_build="${2:?usage: check-xcode-version.sh VERSION BUILD}"

actual="$(xcodebuild -version)"
actual_version="$(awk '/^Xcode / { print $2 }' <<<"$actual")"
actual_build="$(awk '/^Build version / { print $3 }' <<<"$actual")"

[[ "$actual_version" == "$expected_version" ]] ||
  {
    echo "toolchain: expected Xcode $expected_version, found $actual_version" >&2
    exit 1
  }
[[ "$actual_build" == "$expected_build" ]] ||
  {
    echo "toolchain: expected Xcode build $expected_build, found $actual_build" >&2
    exit 1
  }

printf 'toolchain: Xcode %s (%s)\n' "$actual_version" "$actual_build"
