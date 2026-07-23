#!/bin/zsh
set -euo pipefail

log_file="${1:-$HOME/Library/Logs/com.eloe.saymark.local/saymark.jsonl}"

if [[ ! -s "$log_file" ]]; then
  echo "No diagnostic events found at $log_file"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to summarize diagnostics"
  exit 2
fi

echo "Saymark diagnostics: $log_file"
jq -s -r '
  def selected($name): map(select(.event == $name));
  def avg($items): if ($items | length) == 0 then 0 else ($items | add) / ($items | length) end;
  . as $events |
  selected("process.resource_sample") as $resources |
  selected("dictation.pipeline_completed") as $sessions |
  selected("model.load_completed") as $models |
  "events: \($events | length)",
  "range: \(($events | map(.timestamp) | min) // 0) .. \(($events | map(.timestamp) | max) // 0)",
  "resource samples: \($resources | length)",
  "interval CPU avg/max: \(avg($resources | map(.cpu_percent)))% / \(($resources | map(.cpu_percent) | max) // 0)%",
  "resident max: \(((($resources | map(.resident_bytes) | max) // 0) / 1000000000) * 100 | round / 100) GB",
  "physical footprint max: \(((($resources | map(.physical_footprint_bytes) | max) // 0) / 1000000000) * 100 | round / 100) GB",
  "completed dictations: \($sessions | length)",
  "model loads: \($models | length)",
  "",
  "model\trepository\tload_ms\tmlx_peak_gb",
  ($models[]? | [.lane, .repository, (.duration_ms | tostring), ((.mlx_peak_bytes / 1000000000) | tostring)] | @tsv),
  "",
  "session\tmode\taudio_s\trtf\tstep_p95_ms\tfinish_ms\tgated\tmlx_peak_gb",
  ($sessions[]? | [
    .session_id, .mode, (.audio_seconds | tostring), (.compute_rtf | tostring),
    (.asr_step_p95_ms | tostring), (.finish_compute_ms | tostring),
    (.gated_chunks | tostring), ((.mlx_peak_bytes / 1000000000) | tostring)
  ] | @tsv)
' "$log_file"
