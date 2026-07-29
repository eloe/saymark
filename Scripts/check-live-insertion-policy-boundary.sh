#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_root="$repo_root/SaymarkKit/Sources/LiveInsertionPolicy"
package_file="$repo_root/SaymarkKit/Package.swift"
fixture_root="$repo_root/Scripts/fixtures/live-insertion-policy-boundary"
swiftc_command=(swiftc)
if command -v xcrun >/dev/null 2>&1; then
  swiftc_command=(xcrun swiftc)
fi

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
# Do not use a source regex or a home-grown lexer to find imports. Swift permits
# arbitrary trivia around declarations, while comments, strings, and regex
# literals can legitimately contain import-like text. The compiler parser
# represents a real declaration as `(import_decl ...)` in its parse tree.
#
# `-dump-parse` intentionally omits inactive conditional-compilation branches.
# A second compiler pass replaces only conditional directive lines with blank
# lines, exposing every branch to the parser while preserving source locations.
# Any syntax failure in either required pass fails the boundary closed.
forbidden_symbol='(^|[^[:alnum:]_])(AX[A-Za-z0-9_]*|CGEvent[A-Za-z0-9_]*|NSEvent|NSPasteboard|NSAppleScript|NSWorkspace|CFMessagePort|DistributedNotificationCenter|NSXPC|xpc_[A-Za-z0-9_]*|dlopen|dlsym|dladdr|NSClassFromString|objc_lookUpClass|unsafeBitCast|@_silgen_name|@_cdecl|@_expose|@_dynamicReplacement|Process|NSTask|URLSession|Socket)([^[:alnum:]_]|$)'

check_source() {
  local root="$1"
  local source parse_tree matches

  while IFS= read -r -d '' source; do
    if ! parse_tree="$("${swiftc_command[@]}" -swift-version 6 -dump-parse "$source" 2>&1)"; then
      printf '%s\n' "$parse_tree" >&2
      printf '%s: Swift parser rejected source\n' "${source#"$repo_root"/}" >&2
      return 1
    fi

    if grep -Eq '\(import_decl([[:space:]]|$)' <<<"$parse_tree"; then
      printf '%s: explicit Swift import declaration\n' "${source#"$repo_root"/}" >&2
      return 1
    fi

    if grep -Eq '^[[:space:]]*#(if|elseif|else|endif)([[:space:]]|$)' "$source"; then
      if ! parse_tree="$(perl -pe 'if (/^\s*#(?:if|elseif|else|endif)\b/) { s/[^\r\n]/ /g }' "$source" | "${swiftc_command[@]}" -swift-version 6 -dump-parse - 2>&1)"; then
        printf '%s\n' "$parse_tree" >&2
        printf '%s: Swift parser rejected conditionally flattened source\n' "${source#"$repo_root"/}" >&2
        return 1
      fi

      if grep -Eq '\(import_decl([[:space:]]|$)' <<<"$parse_tree"; then
        printf '%s: explicit Swift import declaration in conditional branch\n' "${source#"$repo_root"/}" >&2
        return 1
      fi
    fi
  done < <(find "$root" -type f -name '*.swift' -print0)

  matches="$(find "$root" -type f -name '*.swift' -exec grep -EnE "$forbidden_symbol" {} + || true)"
  [[ -z "$matches" ]] || {
    printf '%s\n' "$matches" >&2
    return 1
  }
}

check_source "$policy_root" || fail "policy target violates the pure-Swift import/dependency boundary"

# Assert the manifest has precisely the no-dependency target declaration. This
# prevents a dependency from being smuggled in while source imports stay clean.
if ! grep -Eq '^        \.target\(name: "LiveInsertionPolicy"\),$' "$package_file"; then
  fail "LiveInsertionPolicy must remain a zero-dependency target"
fi
if grep -Eq '\.target\([[:space:]]*name: "LiveInsertionPolicy",[[:space:]]*dependencies:' "$package_file"; then
  fail "LiveInsertionPolicy may not declare dependencies"
fi

# Negative fixtures make the gate self-testing: every known alternate route
# must be rejected, otherwise the policy check itself fails closed. Typecheck
# them with a package name so `package import` remains a compiler-valid case.
[[ -d "$fixture_root" ]] || fail "missing boundary negative fixtures"
while IFS= read -r -d '' fixture; do
  # Fixtures must remain parser-valid Swift 6. Use parsing rather than module
  # resolution so Apple-only imports remain valid negative cases on Linux CI.
  if ! "${swiftc_command[@]}" -swift-version 6 -package-name LiveInsertionPolicyFixtures -parse "$fixture" >/dev/null 2>&1; then
    fail "negative fixture is not valid Swift 6 syntax: ${fixture#"$repo_root"/}"
  fi

  if check_source "$fixture" >/dev/null 2>&1; then
    fail "negative fixture escaped boundary gate: ${fixture#"$repo_root"/}"
  fi
done < <(find "$fixture_root" -maxdepth 1 -type f -name '*.swift' -print0)

# Positive fixtures prove compiler-derived import detection does not mistake
# comments, strings, raw multiline strings, regex literals, or escaped
# identifiers for declarations.
positive_fixture_root="$fixture_root/allowed"
[[ -d "$positive_fixture_root" ]] || fail "missing boundary positive fixtures"
while IFS= read -r -d '' fixture; do
  if ! "${swiftc_command[@]}" -swift-version 6 -package-name LiveInsertionPolicyFixtures -parse "$fixture" >/dev/null 2>&1; then
    fail "positive fixture is not valid Swift 6 syntax: ${fixture#"$repo_root"/}"
  fi

  if ! check_source "$fixture"; then
    fail "positive fixture was rejected by boundary gate: ${fixture#"$repo_root"/}"
  fi
done < <(find "$positive_fixture_root" -type f -name '*.swift' -print0)

printf 'live-insertion-policy-boundary: PASS\n'
