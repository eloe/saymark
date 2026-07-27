#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_root="$repo_root/SaymarkKit/Sources/LiveInsertionPolicy"
package_file="$repo_root/SaymarkKit/Package.swift"
fixture_root="$repo_root/Scripts/fixtures/live-insertion-policy-boundary"
import_checker="$repo_root/Scripts/check-swift-import-declarations.mjs"

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
# Do not use a source regex to find imports. Swift permits arbitrary comments
# and trivia between attributes/access modifiers and `import`, and source text
# also legitimately contains the word in comments, strings, and regex
# literals. The deterministic lexer skips those lexical regions and examines
# every #if branch, which compiler parse-tree dumps deliberately do not retain.
# Each source is separately compiler-parsed first, so malformed source fails
# closed before the lexical declaration check runs.
forbidden_symbol='\b(AX[A-Za-z0-9_]*|CGEvent[A-Za-z0-9_]*|NSEvent|NSPasteboard|NSAppleScript|NSWorkspace|CFMessagePort|DistributedNotificationCenter|NSXPC|xpc_[A-Za-z0-9_]*|dlopen|dlsym|dladdr|NSClassFromString|objc_lookUpClass|unsafeBitCast|@_silgen_name|@_cdecl|@_expose|@_dynamicReplacement|Process|NSTask|URLSession|Socket)\b'

check_source() {
  local root="$1"
  local source matches

  while IFS= read -r -d '' source; do
    if ! swiftc -swift-version 6 -parse "$source" >/dev/null 2>&1; then
      printf '%s: Swift parser rejected source\n' "${source#$repo_root/}" >&2
      return 1
    fi
  done < <(find "$root" -type f -name '*.swift' -print0)

  if ! node "$import_checker" "$root"; then
    return 1
  fi

  matches="$(rg -n -P --glob '*.swift' -e "$forbidden_symbol" "$root" || true)"
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
# must be rejected, otherwise the policy check itself fails closed. Typecheck
# them with a package name so `package import` remains a compiler-valid case.
[[ -d "$fixture_root" ]] || fail "missing boundary negative fixtures"
while IFS= read -r -d '' fixture; do
  # Fixtures must remain compiler-valid Swift 6. This demonstrates that a
  # rejected form is a genuine import/dependency route, rather than a
  # synthetic string that could never enter the policy target.
  if ! swiftc -swift-version 6 -package-name LiveInsertionPolicyFixtures -typecheck "$fixture" >/dev/null 2>&1; then
    fail "negative fixture is not valid Swift 6 syntax: ${fixture#$repo_root/}"
  fi

  if check_source "$fixture" >/dev/null 2>&1; then
    fail "negative fixture escaped boundary gate: ${fixture#$repo_root/}"
  fi
done < <(find "$fixture_root" -maxdepth 1 -type f -name '*.swift' -print0)

# Positive fixtures prove deterministic lexical import detection does not mistake
# comments, strings, raw multiline strings, regex literals, or escaped
# identifiers for declarations.
positive_fixture_root="$fixture_root/allowed"
[[ -d "$positive_fixture_root" ]] || fail "missing boundary positive fixtures"
while IFS= read -r -d '' fixture; do
  if ! swiftc -swift-version 6 -package-name LiveInsertionPolicyFixtures -typecheck "$fixture" >/dev/null 2>&1; then
    fail "positive fixture is not valid Swift 6 syntax: ${fixture#$repo_root/}"
  fi

  if ! check_source "$fixture"; then
    fail "positive fixture was rejected by boundary gate: ${fixture#$repo_root/}"
  fi
done < <(find "$positive_fixture_root" -type f -name '*.swift' -print0)

printf 'live-insertion-policy-boundary: PASS\n'
