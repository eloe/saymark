#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v zsh >/dev/null 2>&1 ||
  { echo "zsh-syntax: zsh is required" >&2; exit 2; }

zsh_scripts=()
while IFS= read -r script; do
  zsh_scripts+=("$script")
done < <(git grep -lE '^#!(/usr/bin/env zsh|/bin/zsh)$' -- 'Scripts/*.sh')

if ((${#zsh_scripts[@]} == 0)); then
  echo "zsh-syntax: no zsh scripts found" >&2
  exit 1
fi

for script in "${zsh_scripts[@]}"; do
  zsh -n "$script"
done

printf 'zsh-syntax: PASS (%d scripts)\n' "${#zsh_scripts[@]}"
