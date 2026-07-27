#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_root="$repo_root/SaymarkKit/Sources/LiveInsertionPolicy"
package_file="$repo_root/SaymarkKit/Package.swift"
fixture_root="$repo_root/Scripts/fixtures/live-insertion-policy-boundary"

fail() {
  printf 'live-insertion-policy-boundary: %s\n' "$1" >&2
  exit 1
}

[[ -d "$policy_root" ]] || fail "missing isolated LiveInsertionPolicy target"
[[ -n "$(find "$policy_root" -type f -name '*.swift' -print -quit)" ]] || \
  fail "LiveInsertionPolicy has no Swift sources"
[[ -f "$package_file" ]] || fail "missing Package.swift"

# Slice 1 is a zero-dependency pure Swift target.  Scan both direct imports and
# common dynamic, legacy, Objective-C, and accessibility escape hatches; a
# future adapter must live outside this target after the evidence gates close.
forbidden='^[[:space:]]*import[[:space:]]+(ApplicationServices|AppKit|Cocoa|CoreGraphics|Carbon|IOKit|ObjectiveC|Darwin)$|\b(AX[A-Za-z0-9_]*|CGEvent[A-Za-z0-9_]*|NSEvent|NSPasteboard|NSAppleScript|NSWorkspace|dlopen|dlsym|NSClassFromString|objc_lookUpClass|unsafeBitCast|@_silgen_name|Process|NSTask)\b'

check_source() {
  local root="$1"
  local matches
  matches="$(rg -n --glob '*.swift' -e "$forbidden" "$root" || true)"
  [[ -z "$matches" ]] || {
    printf '%s\n' "$matches" >&2
    return 1
  }
}

check_source "$policy_root" || fail "policy target references an automation, dynamic-link, or process dependency"

# Assert the manifest has precisely the no-dependency target declaration. This
# prevents a dependency from being smuggled in while source imports stay clean.
if ! rg -q '^        \.target\(name: "LiveInsertionPolicy"\),$' "$package_file"; then
  fail "LiveInsertionPolicy must remain a zero-dependency target"
fi
if rg -q '\.target\([[:space:]]*name: "LiveInsertionPolicy",[[:space:]]*dependencies:' "$package_file"; then
  fail "LiveInsertionPolicy may not declare dependencies"
fi

# Negative fixtures make the gate self-testing: every known alternate route
# must be rejected, otherwise the policy check itself fails closed.
[[ -d "$fixture_root" ]] || fail "missing boundary negative fixtures"
while IFS= read -r -d '' fixture; do
  if check_source "$fixture"; then
    fail "negative fixture escaped boundary gate: ${fixture#$repo_root/}"
  fi
done < <(find "$fixture_root" -type f -name '*.swift' -print0)

printf 'live-insertion-policy-boundary: PASS\n'
