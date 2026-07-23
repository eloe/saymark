# Diagnostic logging

The local Saymark build writes privacy-safe JSON Lines diagnostics to:

```text
~/Library/Logs/com.eloe.saymark.local/saymark.jsonl
```

The file rotates at 20 MB and retains three older files. The app also sends the
same events to Apple's unified log under the `diagnostics` category.

## Configuration

Choose a level in **Settings → Diagnostics**, or configure a launch persistently:

```bash
defaults write com.eloe.saymark.local saymark.logLevel trace
defaults write com.eloe.saymark.local saymark.logMaxBytes 20971520
```

Environment variables override preferences for a single benchmark launch:

```bash
SAYMARK_LOG_LEVEL=trace \
SAYMARK_LOG_FILE=/tmp/saymark.jsonl \
SAYMARK_LOG_MAX_BYTES=20971520 \
open "/Applications/Saymark.app"
```

Levels are `off`, `error`, `warn`, `info`, `debug`, and `trace`. Local builds
default to `debug`; official builds default to `info`. Debug includes a process
CPU/memory sample every 30 seconds. Trace additionally records each 480 ms audio
processing step.

## Recorded measurements

- app version, build, route, and lifecycle;
- public model repository, load duration, warm-up duration, and reuse;
- microphone format, captured duration, peak RMS, and conversion failures;
- generated session ID shared across capture, inference, UI, and insertion;
- VAD-fed/gated chunk counts and VAD p95 latency;
- queue-delay and ASR step p50/p95/max latency;
- streaming compute, finalization latency, and compute real-time factor;
- result character/word counts and insertion outcome;
- MLX active, cache, and peak allocation;
- process interval CPU, resident memory, and physical footprint.

Saymark never logs audio samples, transcript text, selected text, clipboard
contents, or text from the focused application. Keep diagnostic files local
unless the user explicitly chooses to share them.

## Report

```bash
Scripts/report-diagnostics.sh
Scripts/report-diagnostics.sh /path/to/saymark.jsonl
```

The report validates every JSON line and summarizes resource samples, model
loads, and completed dictations without displaying user content.
