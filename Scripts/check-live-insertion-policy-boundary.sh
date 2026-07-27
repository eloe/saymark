#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_root="$repo_root/SaymarkKit/Sources/LiveInsertionPolicy"

fail() {
  printf 'live-insertion-policy-boundary: %s\n' "$1" >&2
  exit 1
}

[[ -d "$policy_root" ]] || fail "missing isolated LiveInsertionPolicy target"
[[ -n "$(find "$policy_root" -type f -name '*.swift' -print -quit)" ]] || \
  fail "LiveInsertionPolicy has no Swift sources"

forbidden='^[[:space:]]*import[[:space:]]+(ApplicationServices|CoreGraphics)$|AXUIElementSetAttributeValue|CGEvent'
if matches="$(rg -n --glob '*.swift' -e "$forbidden" "$policy_root" || true)"; then
  [[ -z "$matches" ]] || {
    printf '%s\n' "$matches" >&2
    fail "policy target references a platform automation dependency"
  }
fi

printf 'live-insertion-policy-boundary: PASS\n'
