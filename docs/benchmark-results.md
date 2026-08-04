# Model benchmark results

These measurements are decision records, not general hardware claims. The
synthetic fixture verifies repeatability and catches gross regressions; model
promotion still requires the quality corpus in `performance-acceptance.md`.

## 2026-08-03 — Apple silicon Mac16,9, 38.65 GB

- Machine: `Mac16,9`, 38,654,705,664 bytes memory
- macOS: 26.5.1 (25F80)
- Xcode: 26.6 (17F113); Swift 6.3.3
- Saymark commit: `dc1297a6d0d2b8860f34869b3d3ff9f171952a3b`
- MLX Swift: 0.31.6
- MLX Audio Swift: `6671490176d24bc962f0b8cd50dbf24e2427e387`
- Synthetic timing fixture: 24.49-second deterministic `say` recording, one
  complete unmeasured warm-up followed by 20 measured runs
- Corpus: all 17 hash-pinned `saymark-english-v1` cases, including 30, 45, 60,
  90, and 120-second long-form cases
- Parakeet:
  `mlx-community/parakeet-tdt-0.6b-v3@ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`
- Live Preview Nemotron:
  `mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit@7279359e4481b5e9e185a318bd618e429c6d86cd`

Both product profiles passed the same public corpus because Parakeet remains
the authoritative final model. Aggregate-only results are recorded here; the
ignored local JSON contains public reference/hypothesis text and is not
published.

| Profile | Macro WER | Clean | Other | Pink noise | Long form | Violations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Efficient | 4.88% | 0.51% | 8.37% | 6.25% | 5.21% | 0 |
| Live Preview | 4.88% | 0.51% | 8.37% | 6.25% | 5.21% | 0 |

The separate warmed synthetic timing/resource run passed every model-level
budget:

| Profile | Runs | Median RTF | Final median | p95/max step | Peak memory | Settled growth | Smoke WER |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Efficient | 20 | 0.00995 | 0.111 s | 0.0009 / 0.0022 s | 3.80 GB | 0 GB | 3.03% |
| Live Preview | 20 | 0.0801 | 0.128 s | 0.0138 / 0.0235 s | 4.60 GB | 0 GB | 3.03% |

The clean checkout initially stopped before inference because SwiftPM had not
emitted MLX's `mlx-swift_Cmlx.bundle`. An ad-hoc-signed local Xcode app build
with package-plugin validation explicitly skipped produced the 3.82 MB Metal
library; copying that generated bundle into the isolated XCTest resources made
the documented runner reproducible. No app was installed, launched, signed by
an Apple identity, or sent to Apple during that model benchmark preparation.

### Optimized local app idle

A later, separate welcome-state run launched the uninstalled optimized app at
`.build/local-corpus/Build/Products/Release/Saymark.app` from Saymark commit
`028628a98d44b27c9d2ad17e52cd1c4aeb8e61e9`. The app reported version `0.1.1`
and build `1001`, used the local identifier `com.eloe.saymark.local`, and had an
ad-hoc signature with no Team Identifier. After a three-second warm-up,
`Scripts/check-app-resources.sh` collected 30 samples at one-second intervals.

| State | Samples | Median CPU | Nearest-rank p95 CPU | Final RSS | Gate |
| --- | ---: | ---: | ---: | ---: | --- |
| Welcome/onboarding idle | 30 | 0.0% | 0.0% | 68.1 MB | Pass |

The gate was median CPU at most 0.5% and p95 CPU at most 2.0%. The app was
terminated after the measurement. It was not installed, signed by an Apple
identity, notarized, or sent to Apple. This is a process-level welcome-state
idle result: it does not claim model-warm idle, active-capture CPU, retained
post-session resources, shortcut or microphone latency, main-thread stalls,
external-target delivery, or a feature walkthrough.

This evidence closes the real-model WER, long-form, warmed model latency, peak
memory, settled model-memory, and welcome-state idle CPU portions of the
hardware gate on this machine. It does not claim app-level shortcut feedback,
microphone start, model-warm idle, main-thread stall, retained UI resources,
external-target delivery, or a real feature walkthrough; those remain separate
measurements.

## 2026-07-24 — Apple M2, 24 GB

- Machine: MacBook Pro `Mac14,7`
- macOS: 26.5.2
- Saymark base commit: `66478f4731c036a546f13fd93f1fc4dc46422b97`
- Benchmark harness: current working-tree patch that performs the full unmeasured
  transcription described below; this patch must land with this decision record
- MLX Swift: 0.31.4
- MLX Audio Swift: `6671490176d24bc962f0b8cd50dbf24e2427e387`
- Fixture: 24.49-second deterministic `say` recording, one unmeasured
  compilation warm-up followed by 20 measured runs
- Parakeet FP16:
  `mlx-community/parakeet-tdt-0.6b-v3@ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`
- Nemotron 8-bit:
  `mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit@7279359e4481b5e9e185a318bd618e429c6d86cd`
- Silero VAD:
  `mlx-community/silero-vad@7bc17f22d3c0451bd3a6cd71e759b009271ff49a`

| Profile | Median RTF | Final median | p95/max step | MLX peak | Settled growth | Smoke WER | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Efficient | 0.022 | 0.39 s | 0.004 / 0.010 s | 3.80 GB | 0 GB | 3.0% | Pass |
| Live Preview | 0.210 | 0.42 s | 0.115 / 0.375 s | 4.60 GB | 0 GB | 3.0% | Pass |

The synthetic voice pronounced “Saymark” as two words that Parakeet rendered as
“same arc,” accounting for the nonzero smoke WER. This is a repeatability signal,
not a human-speech accuracy estimate.

### Public English corpus status

An initial MINDS-14-backed v1 run reported 25.84% macro WER, but inspection
showed that multiple selected recordings contained material audible sentences
omitted from the dataset row's `transcription` field. The run was rejected as
invalid ground truth, not treated as a Parakeet failure or model baseline, and
its ignored local results file was not committed. The acceptance gates were not
weakened.

The replacement `saymark-english-v1` foundation pins ten complete CC BY 4.0
LibriSpeech utterances from ten speakers—five `test.clean` and five
`test.other`—and deterministically prepares 17 unmodified, noisy, and
30–120-second cases.

The first LibriSpeech preparation reported 6.9916% overall macro WER:
0.5128% `test.clean`, 8.3730% `test.other`, 6.25% noise, and 12.3856%
long-form. Four long cases were healthy—30/45/90/120 seconds reported
5.80/7.00/2.42/5.11%—but the 60-second case reported 41.61%. Direct Parakeet
and segment checks confirmed the audio was present; inspection found the
fixture's five-source cycle repeated the same utterances within roughly 30
seconds and the decoder collapsed that artificial repetition. That preparation
was rejected as a corpus-construction artifact, not recorded as a model
baseline, and the gates were not weakened.

The corrected recipe consumes all ten unique utterances before any repeat and
uses a separately ordered second cycle for 90- and 120-second cases. No
acceptance gate was changed.

Both product profiles passed the corrected 17-case corpus. Their final results
are identical because Parakeet remains the authoritative final model in both
profiles; Nemotron supplies only the provisional Live Preview draft.

- Corpus source manifest SHA-256:
  `5ff6a56c84f927b145c5fb1633b6e14010c4ebbbba899ea88d690e7d5feaf9af`
- Dataset:
  `openslr/librispeech_asr@71cacbfb7e2354c4226d01e70d77d5fca3d04ba1`
- Parakeet:
  `mlx-community/parakeet-tdt-0.6b-v3@ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`
- Live Preview Nemotron:
  `mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit@7279359e4481b5e9e185a318bd618e429c6d86cd`

| Profile | Macro WER | Clean | Other | Pink noise | Long form | Violations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Efficient | 4.88% | 0.51% | 8.37% | 6.25% | 5.21% | 0 |
| Live Preview | 4.88% | 0.51% | 8.37% | 6.25% | 5.21% | 0 |

The local results JSON remains ignored because it contains the public reference
and hypothesis text; the checked-in source manifest and this decision record
identify the reproducible inputs and aggregate outcome. Public v1 is a valid
English baseline for the scenarios it covers. Spoken numbers and punctuation
commands remain required before promoting a different model as a general
product replacement.

The installed app remained open and untouched. A separate 31-sample idle check
reported median CPU 0%, nearest-rank p95 0.3%, maximum 1.2%, and mean 0.06%.
Its physical footprint was 2.0 GB with a historical 4.4 GB peak, consistent with
resident MLX allocations after prior dictation use.

As supplemental process-level readings, `/usr/bin/time` reported end-to-end CPU
usage of approximately 50% for Efficient and 42% for Live Preview when calculated
from user plus system time divided by wall time. Those figures include model load
and the unmeasured warm-up, so they are not inference-only acceptance metrics.

The first Efficient attempt exposed a harness error: model loading did not compile
all lazy MLX paths, so the nominally warmed sample included a one-time 0.617-second
step and failed the maximum-step budget. The CLI and real-model XCTest now execute
one full unmeasured transcription before establishing the memory baseline and
collecting the requested number of samples.

### Live Preview feed-cadence experiment

The same warmed 24.49-second fixture, model revisions, and 20-run acceptance
harness were used at every cadence. All four candidates produced the same final
transcript and passed the Live Preview quality and resource budget.

| Feed | Median RTF | p95/max step | MLX peak | Settled growth | Smoke WER | Result |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 160 ms | 0.220 | 0.052 / 0.142 s | 4.60 GB | 0 GB | 3.0% | Pass; selected |
| 240 ms | 0.248 | 0.075 / 0.124 s | 4.60 GB | 0 GB | 3.0% | Pass |
| 320 ms | 0.244 | 0.078 / 0.102 s | 4.60 GB | 0 GB | 3.0% | Pass |
| 480 ms | 0.240 | 0.116 / 0.234 s | 4.60 GB | 0 GB | 3.0% | Pass; prior baseline |

The 160 ms feed creates three times as many publication opportunities as the
old 480 ms feed, had the lowest median RTF in this run, stayed well ahead of
real time, and showed no settled-memory growth. It is therefore the production
candidate. Merge remains gated on the app-level shortcut-to-visible-text tests;
this offline experiment does not claim word-aligned display or field-mutation
latency.

## 2026-07-21 — Apple M2, 24 GB

- Machine: MacBook Pro `Mac14,7`
- macOS: 26.5.2
- MLX Swift: 0.31.6
- Saymark base commit: `68b4676441ce2265501217844d2918e68ca32403`
- Fixture: 24.26-second deterministic `say` recording, 20 warmed runs
- Parakeet FP16: `mlx-community/parakeet-tdt-0.6b-v3@ed2b7e8`
- Parakeet encoder-int8: `beshkenadze/parakeet-tdt-0.6b-v3-mlx-encoder-int8@b58cb0e`
- Nemotron 8-bit: `mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit@7279359`

| Profile | Parakeet | Median RTF | Final median | p95/max step | MLX peak | Settled growth | Smoke WER |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Efficient | FP16 | 0.0216 | 0.364 s | 0.0089 / 0.2147 s | 3.80 GB | 0 GB | 0% |
| Efficient | encoder-int8 | 0.0236 | 0.435 s | 0.0034 / 0.0117 s | 1.11 GB | 0 GB | 0% |
| Live Preview | FP16 | 0.2123 | 0.472 s | 0.0984 / 0.2333 s | 4.60 GB | 0 GB | 0% |
| Live Preview | encoder-int8 | 0.2137 | 0.559 s | 0.0969 / 0.1323 s | 1.91 GB | 0 GB | 0% |

Encoder-int8 is the leading candidate: it reduces peak MLX allocation by about
71% in Efficient and 59% in Live Preview, while keeping Live Preview throughput
effectively unchanged. It is not the production default until corpus quality is
validated.

## Parakeet Core ML / ANE experiment

The warmed ANE encoder reduced direct Parakeet inference from 0.34 seconds to
0.23 seconds on the fixture. It also added a 1.18 GB artifact, increased measured
peak process footprint from 4.22 GB to 5.06 GB, and increased cached process time
from about 2.8 seconds to 23 seconds. Punctuation differed from the MLX output.
It is therefore not recommended as the default path in its current integration.
