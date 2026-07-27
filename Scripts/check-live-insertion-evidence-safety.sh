#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="$repo_root/Evidence/LiveInsertionNativeReferenceHarness.swift"

fail() {
  printf 'live-insertion-evidence-safety: %s\n' "$1" >&2
  exit 1
}

[[ -f "$harness" ]] || fail "missing native reference harness"
rg -q 'Test-only native macOS reference harness' "$harness" || fail "harness must declare test-only scope"
rg -q 'self-owned' "$harness" || fail "harness must document its self-owned boundary"
rg -q 'protected-field.ax-write-attempts' "$harness" || fail "secure matrix must report protected-field write count"
rg -q 'acknowledgement-usable=false' "$harness" || fail "harness must not claim public AX acknowledgement"
rg -q 'coordinator-fail-closed-evidence=false' "$harness" || fail "self-owned timeout test must not certify coordinator"

# No harness helper may be pulled into production targets. The only mutator in
# the test harness is a self-process experiment; production sources retain no
# AX mutation primitive.
if rg -n 'AXUIElementSetAttributeValue|AXObserverCreate|AXUIElementSetMessagingTimeout' \
    "$repo_root/SaymarkKit/Sources" "$repo_root/Sources"; then
  fail "production source contains AX evidence/mutation primitive"
fi

printf 'live-insertion-evidence-safety: PASS\n'
