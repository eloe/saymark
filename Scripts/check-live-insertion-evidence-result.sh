#!/usr/bin/env bash
set -euo pipefail

log_file="${1:?usage: check-live-insertion-evidence-result.sh /path/to/harness.log}"

fail() {
  printf 'live-insertion-evidence-result: %s\n' "$1" >&2
  exit 1
}

[[ -f "$log_file" ]] || fail "missing harness log: $log_file"
for expected in \
  'b02.read.initial=kAXErrorSuccess' \
  'b02.selection.unchanged.after-read=true' \
  'b02.substitution-detected=true' \
  'b02.selection.unchanged.after-mismatch-read=true' \
  'b01.acknowledgement-usable=false' \
  'b04.protected-field.ax-write-attempts=0' \
  'b04.native-protected-write-tested=false' \
  'b05.coordinator-fail-closed-evidence=false'; do
  rg -F -q "$expected" "$log_file" || fail "expected result missing: $expected"
done

rg -q '^b05\.hung-read\.error=.*off-main=true$' "$log_file" || \
  fail "hung target must run AX read off the main thread"

printf 'live-insertion-evidence-result: PASS (unsafe gates remain blocked)\n'
