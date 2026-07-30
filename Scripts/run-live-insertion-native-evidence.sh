#!/usr/bin/env bash
set -euo pipefail

# Builds and runs only the self-owned native reference harness. It is not a
# Saymark product target and contains no code path to another application.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/Evidence/LiveInsertionNativeReferenceHarness.swift"
output_root="${TMPDIR:-/tmp}/saymark-live-insertion-evidence"
binary="$output_root/LiveInsertionNativeReferenceHarness"

mkdir -p "$output_root"
swiftc -swift-version 5 "$source_file" \
  -o "$binary" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework Foundation
"$binary"
