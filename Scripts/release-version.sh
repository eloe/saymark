#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 {semver|core|prerelease} saymark-v<SemVer-2.0.0>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage

operation="$1"
tag="$2"
prefix="saymark-v"

[[ "$tag" == "$prefix"* ]] || {
  echo "release-version: tag must start with $prefix" >&2
  exit 1
}

version="${tag#"$prefix"}"

# SemVer 2.0.0 grammar. Numeric core and numeric prerelease identifiers reject
# leading zeroes; alphanumeric prerelease and build identifiers allow only
# ASCII letters, digits, and hyphens.
semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'

[[ "$version" =~ $semver_pattern ]] || {
  echo "release-version: tag must contain a valid SemVer 2.0.0 version" >&2
  exit 1
}

case "$operation" in
  semver)
    printf '%s\n' "$version"
    ;;
  core)
    printf '%s\n' "${version%%[-+]*}"
    ;;
  prerelease)
    version_without_build="${version%%+*}"
    if [[ "$version_without_build" == *-* ]]; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
    ;;
  *)
    usage
    ;;
esac
