# Performance acceptance

Saymark treats CPU, memory, latency, and transcription quality as release criteria.
Model changes are not accepted from a single attractive timing result.

## User experiences

- **Efficient**: one final model; transcript appears after release.
- **Live Preview**: a provisional streaming model while speaking, with the same
  final model as Efficient after release.
- Nemotron-only `fast` remains an internal diagnostic profile.
- Arbitrary model pairing is not user-configurable.

## Apple Silicon development gates

All acceptance runs use an arm64 Release build, a warmed model, 20 consecutive
dictations, and the median unless noted otherwise.

| Gate | Efficient | Live Preview |
| --- | ---: | ---: |
| Median real-time factor | <= 0.08 | <= 0.50 |
| Median stop-to-final latency | <= 2.0 s | <= 2.0 s |
| p95 streaming step | <= 0.10 s | <= 0.25 s |
| Maximum streaming step | <= 0.25 s | <= 0.45 s |
| Word error rate | <= 8% | <= 8% |
| Process/MLX peak memory | <= 6.0 GB | <= 6.0 GB |
| Settled growth after repeated runs | <= 0.25 GB | <= 0.25 GB |

Application lifecycle gates:

- Normal idle CPU after warm-up: median <= 0.5%, p95 <= 2.0% over 30 seconds.
- Visible onboarding CPU: median <= 2.0% over 30 seconds.
- Hidden or closed onboarding/HUD: no repeating animation or display updates.
- Twenty back-to-back dictations: settled memory growth <= 0.25 GB.
- No retained HUD windows, timers, update subscriptions, or capture sessions after stop.

Hardware performance gates are opt-in local checks, not generic CI assertions.
Every result must record the Mac model, memory, macOS version, MLX version, model
repository/revision, fixture revision, and whether the first compilation run was excluded.

## Quality corpus

The checked-in synthetic fixture is a smoke test, not an accuracy claim. A model
decision requires a versioned, consented corpus with reference transcripts:

- At least 10 English clips: clean, noisy, accented, numbers, and punctuation.
- At least 5 Russian clips if Russian remains a supported product language.
- At least 5 long clips between 30 and 120 seconds.
- Macro WER <= 8%, with no language or scenario regressing more than 1 absolute
  WER point from the accepted baseline without explicit review.

Never commit private user recordings. Store only redistributable fixtures or a
manifest pointing to locally held consented audio.

## Commands

```bash
make bench-accept-efficient WAV=/path/to/saymark-performance.aiff
make bench-accept-live WAV=/path/to/saymark-performance.aiff
make test-model-efficient
make test-model-live
make test-model-parakeet-int8
make test-model-live-parakeet-int8
Scripts/check-app-resources.sh "/Applications/Saymark.app"
```

The CLI and opt-in XCTest targets exit nonzero when an acceptance budget is
violated. Ordinary unit tests skip real-model inference, so CI does not download
models or compare machine-dependent timings unless explicitly configured.
