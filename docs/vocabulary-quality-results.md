# Vocabulary correction quality evidence

**Evidence date:** 2026-08-03

**Application baseline:** `dc1297a6d0d2b8860f34869b3d3ff9f171952a3b`

**Fixture:** `SaymarkKit/Tests/Fixtures/vocabulary-quality-v1.json`, revision
`synthetic-text-v1`

**Unicode contract:** 15.1.0

**Correction dependency:** `mlx-audio-swift`
`6671490176d24bc962f0b8cd50dbf24e2427e387`

## Environment

- Mac model: Mac16,9, Apple silicon
- Memory: 38,654,705,664 bytes
- macOS: 26.5.1 (25F80)
- Xcode: 26.6 (17F113)
- Swift: 6.3.3

## Result

The versioned fixture freezes four deterministic rules before evaluation and
keeps development examples separate from ten held-out synthetic evaluation
cases. Evaluation covers a proper noun, product name, acronym, URL-like alias,
repeated term, substring negatives, near misses, and general English. It
contains no private recordings, transcripts, or user vocabulary.

Command:

```sh
cd SaymarkKit
swift test --filter VocabularyQualityAcceptanceTests
```

The focused acceptance test, all 22 existing `VocabularyTests`, and the full
SaymarkKit suite passed. The full suite executed 164 tests with two explicit
environment-gated model/corpus skips and no failures.

Observed result:

| Metric | Result | Gate |
| --- | ---: | ---: |
| Target occurrences | 6 | manifest-pinned |
| Eligible negative occurrences | 5 | manifest-pinned |
| Raw target-term surface error | 100% | baseline |
| Corrected target-term surface error | 0% | >=50% relative improvement |
| Relative target-term improvement | 100% | >=50% |
| Corrected target success Wilson 95% CI | 60.97%–100% | reported, not promoted as population evidence |
| False-replacement point rate | 0% | <=1% |
| False-replacement Wilson 95% CI | 0%–43.45% | reported; fixture is deliberately small |
| Raw normalized WER | 36.84% | fixture baseline only |
| Rendered normalized WER | 0% | regression <=0.5 percentage points |
| Correction latency p95 | 0.288 ms | <=10 ms |
| Correction latency maximum | 0.319 ms | <=25 ms |

The test also requires every rendered result to equal the frozen reference and
repeats every correction to prove deterministic output. Existing
`test_I12_latestWinsBacklogAndFinalPriority` separately proves that superseded
draft work cannot publish out of order and that final correction has priority.

## Claim boundary

This is deterministic, model-independent text-level evidence over frozen raw
ASR outputs. It proves the shipped correction layer's mechanics, regression
guard, negative behavior, and latency on the declared machine. It does **not**
claim population-level ASR improvement, speaker/accent coverage, or confidence
that the false-replacement rate is below 1% for natural speech; the interval is
published precisely to prevent that overclaim.

For Saymark 1.0, Vocabulary is documented only as explicit local text
replacement authored by the user—not pronunciation training, model biasing,
or a general recognition-quality improvement. A future statistical promotion
would require the larger versioned, redistributable/consented audio corpus and
streaming fixture described by the SDD. That promotion is not part of the 1.0
product claim.
