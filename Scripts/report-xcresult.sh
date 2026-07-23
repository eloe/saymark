#!/bin/bash
set -euo pipefail

derived_data=${1:-/tmp/saymark-ui-tests}
result=$(find "$derived_data/Logs/Test" -maxdepth 1 -name '*.xcresult' -print | sort | tail -1)

if [[ -z "$result" ]]; then
  echo "No xcresult found under $derived_data/Logs/Test" >&2
  exit 2
fi

echo
echo "Integration results: $result"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  xcrun xcresulttool get test-results tests --path "$result" 2>/dev/null |
  jq -r '.. | objects | select(.nodeType? == "Test Case") | "  \(.result)  \(.name)  (\(.duration))"'

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  xcrun xcresulttool get test-results metrics --path "$result" 2>/dev/null |
  jq -r '.[] | .testRuns[] | .metrics[]
    | select(.displayName == "CPU Time (local)"
      or .displayName == "Memory Peak Physical (local)"
      or .displayName == "Absolute Memory Physical (local)")
    | (.measurements | add / length) as $average
    | if .unitOfMeasurement == "kB" then
        "  \(.displayName): \((($average / 1000) * 100 | round) / 100) MB average"
      elif .unitOfMeasurement == "s" then
        "  \(.displayName): \((($average * 1000) * 100 | round) / 100) ms average"
      else
        "  \(.displayName): \($average | tostring) \(.unitOfMeasurement) average"
      end'
