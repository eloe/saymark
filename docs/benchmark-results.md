# Model benchmark results

These measurements are decision records, not general hardware claims. The
synthetic fixture verifies repeatability and catches gross regressions; model
promotion still requires the quality corpus in `performance-acceptance.md`.

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
