#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failures=0

report_failure() {
  printf 'security-audit: %s\n' "$1" >&2
  failures=$((failures + 1))
}

sensitive_files="$(
  git ls-files |
    grep -Eai '\.(key|pem|p12|pfx|cer|crt|mobileprovision|provisionprofile|keychain|keychain-db)$|(^|/)(credentials|auth)\.json$|(^|/)Secrets\.xcconfig$' ||
    true
)"
if [[ -n "$sensitive_files" ]]; then
  printf '%s\n' "$sensitive_files" >&2
  report_failure "tracked credential, certificate, provisioning, or keychain material"
fi

token_matches="$(
  git grep -nEI \
    '(gh[opsu]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' \
    -- . ':!Scripts/security-audit.sh' ':!.gitleaksignore' ||
    true
)"
if [[ -n "$token_matches" ]]; then
  printf '%s\n' "$token_matches" >&2
  report_failure "current tree contains a credential or private-key pattern"
fi

history_hits=0
while read -r object_id filename; do
  [[ -n "${filename:-}" ]] || continue
  if git cat-file -p "$object_id" 2>/dev/null |
    grep -Eaq '(gh[opsu]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'
  then
    printf 'security-audit: possible historical secret: %s %s\n' "$object_id" "$filename" >&2
    history_hits=$((history_hits + 1))
  fi
done < <(git rev-list --objects --all)
if ((history_hits > 0)); then
  report_failure "Git history contains credential or private-key patterns"
fi

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --source "$repo_root" --redact --no-banner
else
  printf 'security-audit: gitleaks unavailable; built-in checks completed\n'
fi

if ((failures > 0)); then
  printf 'security-audit: FAIL (%d finding groups)\n' "$failures" >&2
  exit 1
fi

printf 'security-audit: PASS\n'
