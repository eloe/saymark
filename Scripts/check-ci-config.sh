#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for tool in actionlint shellcheck; do
  command -v "$tool" >/dev/null 2>&1 ||
    { echo "ci-config: missing required tool: $tool" >&2; exit 2; }
done

actionlint -shellcheck "$(command -v shellcheck)"

bash_scripts=()
while IFS= read -r script; do
  bash_scripts+=("$script")
done < <(git grep -lE '^#!(/usr/bin/env bash|/bin/bash)$' -- 'Scripts/*.sh')

if ((${#bash_scripts[@]} == 0)); then
  echo "ci-config: no Bash scripts found" >&2
  exit 1
fi

shellcheck "${bash_scripts[@]}"

zsh_scripts=()
while IFS= read -r script; do
  zsh_scripts+=("$script")
done < <(git grep -lE '^#!(/usr/bin/env zsh|/bin/zsh)$' -- 'Scripts/*.sh')

for script in "${zsh_scripts[@]}"; do
  zsh -n "$script"
done

printf 'ci-config: PASS (%d Bash scripts, %d zsh scripts)\n' \
  "${#bash_scripts[@]}" "${#zsh_scripts[@]}"
