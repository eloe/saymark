#!/usr/bin/env bash
set -euo pipefail

# Hardware-specific acceptance benchmark. This is intentionally opt-in: the
# wall-clock thresholds belong to the release machine record, not generic CI.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/SaymarkKit"
swift test -c release -Xswiftc -DSAYMARK_POLICY_PERFORMANCE \
  --filter LiveInsertionPolicyTests/testOptInNormalPolicyUpdatePerformanceAcceptance
