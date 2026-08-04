#!/usr/bin/env bash
set -euo pipefail

developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
failures=0
next_command='make test-integration'

pass() {
  printf 'ui-evidence-preflight: PASS — %s\n' "$1"
}

block() {
  printf 'ui-evidence-preflight: BLOCKED — %s\n' "$1" >&2
  failures=$((failures + 1))
}

if [[ $(uname -m) == arm64 ]]; then
  pass "Apple-silicon architecture"
else
  block "Saymark local evidence requires arm64 Apple silicon (found $(uname -m))"
fi

macos_version=$(sw_vers -productVersion)
macos_major=${macos_version%%.*}
if [[ $macos_major =~ ^[0-9]+$ ]] && ((macos_major >= 15)); then
  pass "macOS $macos_version"
else
  block "Saymark requires macOS 15 or later (found $macos_version)"
fi

xcodebuild_path="$developer_dir/usr/bin/xcodebuild"
if [[ -x $xcodebuild_path ]]; then
  xcode_version_output=$(DEVELOPER_DIR="$developer_dir" "$xcodebuild_path" -version 2>&1 || true)
  xcode_version=$(printf '%s\n' "$xcode_version_output" | awk '/^Xcode / { print $2; exit }')
  xcode_major=${xcode_version%%.*}
  if [[ $xcode_major == 26 ]]; then
    pass "Xcode $xcode_version under $developer_dir"
  else
    block "Saymark local evidence requires a compatible Xcode 26 release under $developer_dir (found ${xcode_version:-unknown})"
  fi
  if DEVELOPER_DIR="$developer_dir" "$xcodebuild_path" -checkFirstLaunchStatus >/dev/null 2>&1; then
    pass "Xcode first-launch components"
  else
    block "finish Xcode setup with: sudo DEVELOPER_DIR='$developer_dir' xcodebuild -runFirstLaunch"
  fi
else
  block "xcodebuild is unavailable under DEVELOPER_DIR=$developer_dir"
fi

pinned_tuist=$(awk -F'"' '/^[[:space:]]*tuist[[:space:]]*=/ { print $2; exit }' "$repo_root/.mise.toml")
tuist_version=''
if command -v tuist >/dev/null 2>&1; then
  tuist_version=$(tuist version 2>/dev/null || true)
elif command -v mise >/dev/null 2>&1 && mise which tuist >/dev/null 2>&1; then
  tuist_version=$(mise exec -- tuist version 2>/dev/null || true)
  next_command='mise exec -- make test-integration'
fi
if [[ -n $pinned_tuist && $tuist_version == "$pinned_tuist" ]]; then
  pass "repository-pinned Tuist $tuist_version"
else
  block "install the repository-pinned Tuist ${pinned_tuist:-version} with: mise install"
fi

developer_mode=$(/usr/sbin/DevToolsSecurity -status 2>&1 || true)
if [[ $developer_mode == *enabled* ]]; then
  pass "Developer Mode"
else
  block "Developer Mode is disabled"
  printf 'ui-evidence-preflight: ACTION — while at the Mac, run: sudo /usr/sbin/DevToolsSecurity -enable\n' >&2
fi

if ((failures > 0)); then
  printf 'ui-evidence-preflight: %d blocking machine prerequisite(s); no Apple Developer membership is required\n' "$failures" >&2
  exit 2
fi

printf 'ui-evidence-preflight: READY — run %s; approve only the macOS prompts for the displayed local runner identity\n' "$next_command"
