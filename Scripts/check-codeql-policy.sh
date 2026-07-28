#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="$repo_root/Scripts/select-codeql-policy.sh"
checks=0

check_policy() {
  local name="$1"
  local event_name="$2"
  local git_ref="$3"
  local pr_draft="$4"
  local codeql_required="$5"
  local expected_draft="$6"
  local expected_suite="$7"
  local expected_run="$8"
  local actual expected

  actual="$(
    "$selector" "$event_name" "$git_ref" "$pr_draft" "$codeql_required" \
      2>/dev/null
  )"
  expected="$(
    printf 'draft_deferred=%s\nquery_suite=%s\nrun_codeql=%s\n' \
      "$expected_draft" "$expected_suite" "$expected_run"
  )"

  if [[ "$actual" != "$expected" ]]; then
    printf 'codeql-policy: FAIL (%s)\nexpected:\n%s\nactual:\n%s\n' \
      "$name" "$expected" "$actual" >&2
    exit 1
  fi

  ((checks += 1))
}

check_policy "normal pull request" \
  pull_request refs/pull/1/merge false false false default false
check_policy "normal draft" \
  pull_request refs/pull/1/merge true false false default false
check_policy "labeled pull request" \
  pull_request refs/pull/1/merge false true false default true
check_policy "labeled draft" \
  pull_request refs/pull/1/merge true true true default false
check_policy "main push" \
  push refs/heads/main false false false default true
check_policy "release tag" \
  push refs/tags/saymark-v1.0.0 false false false security-extended true
check_policy "scheduled scan" \
  schedule refs/heads/main false false false security-extended true
check_policy "manual scan" \
  workflow_dispatch refs/heads/main false false false security-extended true

if "$selector" pull_request refs/pull/1/merge false >/dev/null 2>&1; then
  echo "codeql-policy: FAIL (invalid argument count was accepted)" >&2
  exit 1
fi

printf 'codeql-policy: PASS (%d event policies)\n' "$checks"
