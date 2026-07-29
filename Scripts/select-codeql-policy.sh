#!/usr/bin/env bash
set -euo pipefail

if (($# != 4)); then
  echo "usage: $0 <event-name> <git-ref> <pr-draft> <codeql-required>" >&2
  exit 2
fi

event_name="$1"
git_ref="$2"
pr_draft="$3"
codeql_required="$4"

emit_policy() {
  printf 'draft_deferred=%s\nquery_suite=%s\nrun_codeql=%s\n' "$1" "$2" "$3"
}

if [[ "$event_name" == "pull_request" ]]; then
  if [[ "$codeql_required" != "true" ]]; then
    emit_policy false default false
    echo "Deferring full CodeQL analysis until the change reaches main." >&2
    exit 0
  fi

  if [[ "$pr_draft" == "true" ]]; then
    emit_policy true default false
    echo "The codeql-required scan is deferred while the pull request is a draft." >&2
    exit 0
  fi

  emit_policy false default true
  echo "The codeql-required label selected a blocking pull-request scan." >&2
  exit 0
fi

if [[ "$event_name" == "push" && "$git_ref" == "refs/heads/main" ]]; then
  emit_policy false default true
  echo "Running the default CodeQL suite after merge to main." >&2
  exit 0
fi

emit_policy false security-extended true
echo "Running the extended CodeQL suite for $event_name on $git_ref." >&2
