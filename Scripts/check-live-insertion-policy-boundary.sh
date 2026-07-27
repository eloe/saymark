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

# Slice 1 is a zero-dependency pure Swift target. The import allowlist is
# deliberately empty: `Swift` is implicit, so any explicit module import fails
# closed. This excludes Foundation/CoreFoundation/XPC/IPC as well as UI and AX
# frameworks. A future adapter must live outside this target after evidence.
# A policy source has an empty import allowlist. Swift permits attributes before
# imports, scoped conditional imports, semicolon-separated imports, and import
# kind modifiers; match every one of those forms. `rg -P` supplies the
# multiline attribute support that POSIX grep deliberately lacks.
forbidden_import='(?ms)(?:^|[;{}])[[:space:]]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:[[:space:]]*\([^)]*\))?[[:space:]]*)*\bimport[[:space:]]+(?:(?:func|class|struct|enum|protocol|var|let|typealias|operator)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*'
forbidden_symbol='\b(AX[A-Za-z0-9_]*|CGEvent[A-Za-z0-9_]*|NSEvent|NSPasteboard|NSAppleScript|NSWorkspace|CFMessagePort|DistributedNotificationCenter|NSXPC|xpc_[A-Za-z0-9_]*|dlopen|dlsym|dladdr|NSClassFromString|objc_lookUpClass|unsafeBitCast|@_silgen_name|@_cdecl|@_expose|@_dynamicReplacement|Process|NSTask|URLSession|Socket)\b'

check_source() {
  local root="$1"
  local matches
  matches="$(rg -n -P --glob '*.swift' -e "$forbidden_import" -e "$forbidden_symbol" "$root" || true)"
  [[ -z "$matches" ]] || {
    printf '%s\n' "$matches" >&2
    return 1
  }
}

check_source "$policy_root" || fail "policy target violates the pure-Swift import/dependency boundary"

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
