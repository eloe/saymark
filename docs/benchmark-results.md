# Model benchmark results

These measurements are decision records, not general hardware claims. The
synthetic fixture verifies repeatability and catches gross regressions; model
promotion still requires the quality corpus in `performance-acceptance.md`.

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
