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
- Hidden or closed onboarding/HUD/halo: no repeating animation or display
  updates.
- Start/Stop listening halo: one short bloom may settle into a static edge;
  never continuously pulse.
- Twenty back-to-back dictations: settled memory growth <= 0.25 GB.
- No retained HUD windows, timers, update subscriptions, or capture sessions after stop.

## Human-perceived live insertion gates

Live insertion is accepted only when it feels like writing, not delayed
captioning. These human-visible gates are release criteria independent of model
real-time factor:

| Human-visible event | p50 | p95 | Hard limit |
| --- | ---: | ---: | ---: |
| Hotkey down to first visible listening feedback | <= 50 ms | <= 100 ms | 200 ms |
| End of a decodable word to that word appearing | <= 250 ms | <= 400 ms | 500 ms |
| New transcript hypothesis to completed field mutation | <= 50 ms | <= 100 ms | 150 ms |
| Stop gesture to final settled text | <= 300 ms | <= 500 ms | 750 ms |

During continuous speech:

- The production audio/inference feed cadence must be between 100 and 160 ms.
- A target eligible for live **field** insertion has a stricter maximum streaming
  step of <= 300 ms. It may not rely on the general Live Preview 450 ms maximum:
  one such step would itself violate the visible-freeze gate below.
- No visible transcript freeze may exceed 300 ms while speech and hypotheses
  continue.
- Field updates must remain ordered and must not build an inference or insertion
  backlog.
- Timing variance must be reported; a low median does not compensate for visible
  p95 stalls.
- A correction must replace only Saymark-owned provisional text.
- Focus, selection, cursor, or user-edit changes must stop revision safely rather
  than overwrite text Saymark no longer owns.
- Atomic final insertion remains the required compatibility fallback.

For live field insertion, word-appearance timing measures provisional text. The
committed-prefix policy must also report and pass these stability limits: no
committed word is revoked; provisional revision depth is at most four words; and
p95 provisional revoked-word rate is <= 2 words/s. The initial policy values are
documented in [`live-insertion-sdd.md`](live-insertion-sdd.md); changing them
requires the same evidence review as changing feed cadence.

These are initial product thresholds, not universal psychophysical constants.
Validate them with observed user testing as well as automated measurement. A
release fails when users visibly wait for half-second transcript bursts even if
the aggregate real-time factor passes.

### Measurement anchors

Measure each boundary separately:

- `hotkey_down` to the first committed listening-state frame. The HUD is the
  required signal in both modes; the perimeter halo is additional Start/Stop
  feedback and does not replace the HUD gate;
- aligned end time of a reference word in a consented fixture to the first frame
  containing that word;
- streaming hypothesis publication to completion of the corresponding target
  field mutation;
- intervals between consecutive visible transcript changes;
- stop input event to the final field mutation with no provisional tail;
- emitted hypothesis sequence to revision depth and revoked-word count.

Word-aligned latency requires versioned benchmark audio with reference word
timestamps. Production diagnostics may record only content-free durations,
counts, and outcome categories.

### Slice 1 policy-core acceptance

The pure policy core has deterministic resource limits independent of hardware
model timing. Release validation records an arm64 Release result for the exact
commit and toolchain, and fails the slice when any of the following is false:

| Check | Acceptance requirement |
| --- | --- |
| Per-update work | A normal eligible hypothesis (committed prefix plus <=64 UTF-16 tail) completes in <=1 ms p95 and <=5 ms maximum across 10,000 warmed updates. An oversized tail throttles before fragment expansion. |
| Retained policy state | <=128 UTF-16 code units for a no-tail live candidate; after tail overflow, no HUD-only recogniser content is retained. The external transcript/HUD owner is measured separately. |
| Queue/backlog | Latest-wins capacity is exactly one; 100,000 replaces retain only the newest item and create no queue growth. |
| Cancellation/invalidation | 10,000 deterministic and 500 task-scheduled interleavings of hypothesis, acknowledgement, throttle, secure-input, ownership loss, and Stop produce no post-terminal route or revived tracker. |
| Counter retirement | Generation/serial exhaustion retires mutation issuance; it never wraps into a valid token. |
| Memory | 20 repetitions of the 10,000-update schedule have <=1 MB settled RSS growth attributable to the policy harness after autorelease cleanup; record baseline, peak, and settled values. |

The time and memory figures are measured by an opt-in local performance harness,
not generic CI. CI executes the deterministic overflow, boundary, and
concurrency/invalidation schedules as correctness tests. These Slice 1 limits
do not relax the user-visible live-insertion gates above.

### Feed-cadence experiment

The production feed is 160 ms. It was selected from a 160, 240, 320, and 480 ms
same-fixture experiment recorded in `benchmark-results.md`. Repeat that full
experiment before changing the cadence. Record:

- speech-to-visible-word p50 and p95;
- hypothesis-to-field-mutation p50 and p95;
- maximum visible freeze;
- streaming-step p50, p95, and maximum;
- real-time factor and accumulated backlog;
- provisional-to-final word distance and revoked words per second;
- CPU, energy impact, MLX peak memory, and settled growth.

The selected production cadence must satisfy the human-visible gates and the
existing quality/resource gates. A faster cadence is rejected if inference
falls behind real time, correction stability degrades materially, or resource
budgets fail.

Hardware performance gates are opt-in local checks, not generic CI assertions.
Every result must record the Mac model, memory, macOS version, MLX version, model
repository/revision, fixture revision, and whether the first compilation run was excluded.

## Quality corpus

The checked-in synthetic fixture is a smoke test, not an accuracy claim. A model
decision requires a versioned corpus of redistributable public audio or
explicitly consented local recordings with reference transcripts:

- At least 10 English clips: clean, noisy, accented, numbers, and punctuation.
- At least 5 Russian clips if Russian remains a supported product language.
- At least 5 long clips between 30 and 120 seconds.
- Macro WER <= 8%, with no language or scenario regressing more than 1 absolute
  WER point from the accepted baseline without explicit review.

Never commit private user recordings. Store only redistributable fixtures or a
manifest pointing to locally held consented audio.

### Public English v1

`Benchmarks/Corpus/saymark-english-v1.json` pins ten complete CC BY 4.0
LibriSpeech utterances by dataset revision, row identity, speaker, reference
transcript, duration, and raw SHA-256. The preparation recipe creates:

- 10 unmodified short cases from ten speakers: 5 `test.clean` and 5
  `test.other`;
- 2 deterministic pink-noise cases; and
- 5 long-form composites at 30, 45, 60, 90, and 120 seconds.

Generated audio is local and ignored by Git. Preparation must fail if the
upstream revision, row, transcript, duration, or source bytes differ.
Long-form cases must use every selected unique utterance before repetition when
the duration permits. The 90- and 120-second cases use a separately ordered
second cycle so repeated content is not adjacent or mechanically periodic.

The opt-in runner loads the selected model stack once and reports every case,
macro WER, scenario WER, and locale WER as JSON. Acceptance requires:

- macro WER <= 8%;
- every scenario macro WER <= 12%;
- every locale macro WER <= 12%; and
- with `SAYMARK_CORPUS_BASELINE` set, no scenario or locale may regress by more
  than 1 absolute WER point from the accepted result.

This revision covers multiple speakers, both LibriSpeech acoustic conditions,
noise, and long-form behavior. It does not yet satisfy the full spoken-number
and punctuation-command coverage requirement above; model promotion remains
blocked on adding those public or consented fixtures and recording a passing
result.

## Commands

```bash
make bench-accept-efficient WAV=/path/to/saymark-performance.aiff
make bench-accept-live WAV=/path/to/saymark-performance.aiff
make test-model-efficient
make test-model-live
make test-model-parakeet-int8
make test-model-live-parakeet-int8
make prepare-corpus
make test-corpus-efficient
make test-corpus-live
Scripts/check-app-resources.sh "/Applications/Saymark.app"
```

The CLI and opt-in XCTest targets exit nonzero when an acceptance budget is
violated. Ordinary unit tests skip real-model inference, so CI does not download
models or compare machine-dependent timings unless explicitly configured.
