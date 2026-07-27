#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 <repository-relative-path>" >&2
  exit 2
fi

path="$1"

case "$path" in
  Sources/*.swift | \
    SaymarkKit/Sources/*.swift | \
    Project.swift | \
    */Project.swift | \
    Workspace.swift | \
    */Workspace.swift | \
    Package.swift | \
    */Package.swift | \
    Package.resolved | \
    */Package.resolved | \
    .package.resolved | \
    *.entitlements | \
    *.pbxproj | \
    *.plist | \
    *.xcconfig | \
    *.xcscheme | \
    .github/workflows/codeql.yml | \
    .github/workflows/codeql.yaml | \
    .github/codeql.yml | \
    .github/codeql.yaml | \
    .github/codeql/* | \
    .mise.toml | \
    Scripts/check-xcode-version.sh | \
    Scripts/codeql-path-is-relevant.sh)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
