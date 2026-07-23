#!/bin/bash
set -euo pipefail

app_path=${1:-/Applications/Saymark.app}
samples=${SAMPLES:-30}
interval=${INTERVAL_SECONDS:-1}
max_median_cpu=${MAX_MEDIAN_CPU:-0.5}
max_p95_cpu=${MAX_P95_CPU:-2.0}

pid=$(pgrep -f "${app_path}/Contents/MacOS/Saymark" | head -1 || true)
if [[ -z "$pid" ]]; then
  echo "Saymark is not running from: $app_path" >&2
  exit 2
fi

cpu_file=$(mktemp -t saymark-cpu)
trap 'rm -f "$cpu_file"' EXIT

for ((i = 0; i < samples; i++)); do
  ps -p "$pid" -o %cpu= | awk '{$1=$1; print}' >> "$cpu_file"
  sleep "$interval"
done

median=$(sort -n "$cpu_file" | awk '{v[NR]=$1} END {print v[int((NR+1)/2)]}')
p95=$(sort -n "$cpu_file" | awk '{v[NR]=$1} END {i=int(NR*0.95); if (i < NR*0.95) i++; print v[i]}')
rss_mb=$(ps -p "$pid" -o rss= | awk '{printf "%.1f", $1 / 1024}')

echo "pid=$pid median_cpu=${median}% p95_cpu=${p95}% rss=${rss_mb}MB samples=$samples"

awk -v actual="$median" -v maximum="$max_median_cpu" 'BEGIN {exit !(actual > maximum)}' && {
  echo "FAIL: median CPU ${median}% > ${max_median_cpu}%" >&2
  exit 3
}
awk -v actual="$p95" -v maximum="$max_p95_cpu" 'BEGIN {exit !(actual > maximum)}' && {
  echo "FAIL: p95 CPU ${p95}% > ${max_p95_cpu}%" >&2
  exit 3
}

echo "PASS: idle CPU budget"
