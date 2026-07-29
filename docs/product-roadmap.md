# Product roadmap

Saymark's long-term goal is to be a dependable, open-source voice-writing
application for macOS: fast enough to use all day, private by default, useful
without an account, and extensible without making users assemble a graph of
speech and language models.

This is an engineering roadmap, not a feature-parity claim. A capability is
shipped only after its tests and acceptance gates pass. Dates are intentionally
omitted; measured quality determines promotion.

## Product contract

Saymark should optimize for these outcomes, in order:

1. **Trustworthy daily dictation** — the shortcut, HUD, transcription, and
   insertion work predictably without runaway CPU or memory.
2. **Useful text, not just raw speech** — vocabulary and optional formatting
   reduce the editing users do after dictation.
3. **Local-first control** — core transcription works offline; any network use
   is explicit, visible, and replaceable.
4. **Native macOS behavior** — standard controls, accessibility, keyboard
   navigation, and restrained system-aligned presentation.
5. **Open, inspectable extension points** — model and provider integrations have
   documented contracts rather than hidden product policy.

Efficient and Live Preview remain the two product-level transcription
experiences:

- **Efficient** loads the authoritative final model and emits the transcript
  after the shortcut is released.
- **Live Preview** adds a provisional streaming draft while recording and uses
  the same authoritative final-model policy on release.

They are engine choices, not output modes. Voice, Message, Note, Email, and
custom formatting should work with either experience. Users should not need to
select or coordinate two speech models; model composition stays an
implementation detail governed by benchmarks.

## Where the project stands

The current source already contains:

- global hold and toggle shortcuts;
- a click-through active-display halo for Start/Stop listening, with
  reduced-motion behavior and brief success feedback;
- local Apple-silicon transcription with Efficient and Live Preview plans;
- immediate HUD presentation, provisional text, final text, and error states;
- automatic insertion with clipboard restoration and secure-input fallback;
- guided microphone and draggable Accessibility setup, shortcut behavior,
  download, and hotkey-only try-it onboarding;
- privacy-safe local diagnostics for latency, CPU, memory, MLX allocation, and
  transcript counts;
- unit, app/HUD, XCUITest, and opt-in real-model benchmark targets.

The checked-in public English corpus now provides a reproducible clean, harder
acoustic, noisy, and 30–120-second baseline. It does not yet cover spoken
numbers, punctuation commands, conversational dictation, or multiple promoted
languages, so Saymark still does not make a general accuracy claim.

## Release discipline

Every slice begins with a failing test or a checked-in acceptance fixture. A
slice is complete only when:

- unit tests cover policy and failure behavior;
- XCUITest covers its user-visible critical path;
- the privacy test confirms that logs and telemetry contain no audio,
  transcripts, selected text, application text, or clipboard content;
- the Release build passes the existing gates in
  [`performance-acceptance.md`](performance-acceptance.md);
- results include hardware, OS, app revision, dependency revision, model
  repository/revision, and fixture revision;
- documentation distinguishes local processing from any optional network path.

Machine-dependent performance runs use 20 warmed repetitions and report median,
p95, and maximum values. Correctness tests run in CI; real-model promotion runs
on declared Apple-silicon reference machines.

## Slice 1 — Prove the daily-driver loop

**Outcome:** short and long dictation feels immediate, remains visible while the
user speaks, and inserts exactly once into the intended application.

Deliverables:

- a versioned, consented audio manifest covering short, 3–5 sentence, 30-second,
  60-second, and 120-second utterances;
- XCUITest coverage for shortcut-to-HUD, recording-to-processing, successful
  insertion, clipboard preservation, no-speech, missing Accessibility, and
  secure-input fallback;
- an application compatibility harness for a native text view, web text area,
  Electron field, and terminal;
- long-text HUD wrapping, scrolling or expansion behavior with no flash-only
  state;
- one command that produces a red/green acceptance report from app diagnostics.

Implementation status: `make daily-driver-check` enforces the observed HUD,
stop-to-final, inference, memory, insertion, and privacy gates. The deterministic
XCUITest harness covers the real registered shortcut, all delivery outcomes,
and ten exact-once repetitions for each compatibility target. A final unlocked
interactive-session run remains required before Slice 1 is promoted; macOS
correctly disables HID/UI automation while the user session is locked.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Shortcut down to first visible listening feedback, p95 / max | <= 100 ms / <= 200 ms |
| Microphone capture start, p95 | <= 250 ms |
| Stop-to-final median / p95 | <= 2.0 s / <= 3.0 s |
| Successful single insertion | 100% across 10 repetitions per compatibility target |
| Clipboard restoration | 100%, without overwriting a newer user copy |
| 30–120 second HUD | no clipped final text and no main-thread stall > 100 ms |
| Warm idle CPU median / p95 | <= 0.5% / <= 2.0% |
| Twenty-run settled memory growth | <= 0.25 GB |
| Retained per-session resources after stop | zero capture sessions, HUD subscriptions, and repeating timers |

The existing real-time-factor, streaming-step, WER, and 6 GB peak-allocation
ceilings continue to apply. This is the recommended first implementation slice:
it converts the work already in the repository into a repeatable daily-driver
contract before new feature paths multiply the failure surface.

### Planned follow-up — Live field insertion

Once the atomic daily-driver loop is promoted, in-field dictation should write
stable words at the cursor while the user speaks. This is a planned product
direction, not current shipped behavior: current builds show provisional text
in the HUD and paste the final transcript once.

Live insertion must use a committed-prefix / revisable-tail ownership model.
Saymark may replace only text it inserted provisionally; a focus, selection,
cursor, or user-edit change must stop revision without overwriting user-owned
text. Atomic final insertion remains the compatibility fallback for apps or
states where safe revision cannot be proven. The latency and ownership gates in
[`performance-acceptance.md`](performance-acceptance.md#human-perceived-live-insertion-gates)
are the release contract for this follow-up.

## Slice 2 — Vocabulary and correction

**Outcome:** users can teach Saymark names, product terms, acronyms, and preferred
spellings without sending that vocabulary off-device.

Deliverables:

- local vocabulary management with import, export, search, enable/disable, and
  delete;
- deterministic normalization for explicitly configured heard-to-write
  replacements, including user-authored aliases for URLs, emails, and acronyms;
  built-in parsing/normalization of those forms is deferred;
- a documented adapter boundary for model-native prompting or biasing where a
  speech model supports it;
- per-entry tests and a separately consented, local-only diagnostic that reports
  only privacy-bucketed aggregate match counts, never vocabulary values or remote
  telemetry.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Target-term error rate | >= 50% relative reduction on the vocabulary corpus |
| General macro WER regression | <= 0.5 absolute percentage points |
| False replacement rate | <= 1% across negative fixtures |
| Added stop-to-final latency, p95 | <= 100 ms |
| Vocabulary at rest | local only, user-exportable, excluded from diagnostics |

## Slice 3 — Local history and file transcription

**Outcome:** users can recover recent work and transcribe existing audio without
turning Saymark into a hidden recording archive.

Deliverables:

- a file transcription flow with progress, cancellation, and retry;
- explicit handling for supported audio and video containers;
- searchable local history with copy, export, and delete; the separately scoped
  Recent Dictations recovery feature may ship copy/delete before export and must
  not claim Slice 3 completion until the export design and its acceptance gate
  are implemented;
- retention choices including Off, session-only, and a bounded duration;
- history disabled until the user makes an explicit choice, with audio retention
  separately controlled from transcript retention.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Imported-file transcript | same WER gate as microphone fixtures |
| One-hour file processing | completes without unbounded memory growth |
| Cancellation | stops inference and releases per-job resources within 2 s |
| History search, 10,000 records | p95 <= 100 ms on the reference Mac |
| Delete behavior | integration-tested, with no orphaned transcript/index metadata; byte-level removal from current store artifacts is verified |
| Export behavior (when export scope is implemented) | integration-tested, with no orphaned audio or metadata |
| Default data behavior | no retained audio and no cloud transfer |

## Slice 4 — Formatting modes and provider boundary

**Outcome:** a transcript can become a clean message, email, note, or
user-defined format while faithful raw transcription always remains available.

Deliverables:

- built-in Voice, Message, Email, and Note modes;
- custom instructions with preview, duplicate, import, and export;
- a provider-neutral transformation interface supporting a local processor
  first and optional bring-your-own-key providers later;
- a visible review or fallback path that never destroys the raw transcript;
- per-mode shortcuts, menu selection, and deep links.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Required-format adherence | >= 95% on versioned mode fixtures |
| Names, numbers, URLs, and negation preservation | >= 99% exact-field accuracy |
| Unsupported factual additions | zero in the release evaluation corpus |
| Local transformation p95 | <= 2.0 s for a 100-word transcript |
| Network behavior | zero requests in Voice mode and all explicitly local modes |
| Provider failure | raw transcript remains available and insertable |

Formatting quality requires both automated assertions and a blinded human rubric.
The corpus, rubric, processor version, temperature, and prompt revision must be
recorded with the result; a single attractive example is not evidence.

## Slice 5 — Context-aware workflows

**Outcome:** Saymark can adapt output to the active app or selected text without
silently collecting unrelated screen contents.

Deliverables:

- separately permissioned selected-text, active-application, and clipboard
  context sources;
- an inspect-before-send view for any network processor;
- per-app mode rules, explicit precedence, and a quick temporary override;
- application deny-lists and automatic exclusion of secure fields;
- context-size limits and structured redaction hooks.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Correct per-app mode activation | 100% across the versioned application matrix |
| Context isolation | only enabled sources appear in processor requests |
| Deny-list and secure-field leakage | zero bytes of captured context |
| Rule-evaluation overhead, p95 | <= 25 ms |
| Context-disabled behavior | byte-for-byte equivalent request to the non-context mode |
| Accessibility regressions | zero across shortcut, insertion, and onboarding UI tests |

Context collection is off by default. The product must show which context sources
will be used before a user enables them.

## Slice 6 — Languages and translation

**Outcome:** supported languages are selected or detected honestly, and
translation is an explicit operation rather than an accidental side effect.

Deliverables:

- a capability registry derived from the active speech and transformation
  models;
- language selection, validated automatic detection, and clear unsupported
  states;
- opt-in translation with source and target language visible;
- separate accuracy reports per language and acoustic scenario.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Language identification | >= 98% on supported-language fixtures >= 5 s |
| Transcription quality | macro WER <= 8% per promoted language |
| Worst scenario regression | <= 1 absolute WER point from its accepted baseline |
| Translation quality | passes a published bilingual human rubric with no meaning-changing error |
| Code-switch handling | documented and tested; never advertised when unsupported |

No language count appears in product copy until that language has a published
fixture manifest and accepted result.

## Slice 7 — Meetings and long-form work

**Outcome:** Saymark can process interviews and meetings with timestamps and
optional speaker separation while remaining responsive.

Deliverables:

- long-running recording with pause, resume, recovery, and visible duration;
- timestamped segments, editable speaker labels, and export;
- optional local diarization behind a declared model/download boundary;
- bounded-memory chunking and recoverable intermediate state.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Two-hour recording | completes without data loss or unbounded memory growth |
| UI responsiveness during processing | no main-thread stall > 100 ms |
| Timestamp median absolute error | <= 500 ms on aligned fixtures |
| Diarization error rate | <= 15% on the declared meeting corpus |
| Crash recovery | restores all audio committed before the final 5 s window |
| User deletion | removes recording, transcript, segments, and derived metadata |

## Slice 8 — Optional sync and additional platforms

**Outcome:** users may carry configuration between devices without making an
account or cloud service a prerequisite for local dictation.

Deliverables:

- a versioned, documented settings/modes/vocabulary export format;
- end-to-end encrypted opt-in sync, or a replaceable adapter for a user-selected
  store;
- conflict handling, recovery keys, remote-device revocation, and delete-all;
- platform work only after the macOS core has a stable portable boundary.

Acceptance gates:

| Measure | Gate |
| --- | ---: |
| Offline macOS behavior | fully functional with sync disabled or unavailable |
| Plaintext sensitive data at the service boundary | zero |
| Two-device convergence | 100% across create/update/delete conflict fixtures |
| Account deletion | server and local sync metadata removed and verified |
| Cross-platform quality | each platform passes its own native integration and performance gates |

## Competitive reference, not a parity checklist

As of 2026-07-24, Superwhisper's public documentation describes system-wide
dictation, local and cloud voice models, built-in and custom processing modes,
application/selected-text/clipboard context, per-app activation rules, language
selection and translation, file transcription, history, vocabulary, diarization,
and device sync. These sources inform the problem areas above:

- [Introduction and feature overview](https://superwhisper.com/docs/get-started/introduction)
- [Modes and auto-activation](https://superwhisper.com/docs/modes/modes)
- [Custom instructions and context sources](https://superwhisper.com/docs/modes/custom)
- [macOS voice-to-text and file workflow](https://superwhisper.com/voice-to-text-mac)
- [Public changelog](https://superwhisper.com/changelog)

Saymark does not need to reproduce every implementation choice. Its
differentiation is a measurable local-first core, transparent resource budgets,
inspectable privacy boundaries, and open interfaces. Competitive evaluation
should compare task outcomes—time to usable text, corrections required,
reliability, and resource cost—rather than feature counts alone.

## Scorecard

Every release candidate should publish this compact scorecard:

| Area | Required evidence |
| --- | --- |
| Speed | shortcut-to-HUD, capture-start, stop-to-final, and real-time factor |
| Quality | macro and scenario WER, target-term accuracy, formatting rubric |
| Reliability | insertion matrix, long-session runs, failure and recovery tests |
| Resources | idle CPU, active CPU, process footprint, MLX peak, settled growth |
| Privacy | network inventory, data-retention behavior, redacted-log tests |
| Accessibility | keyboard-only flow, VoiceOver labels, contrast, reduced motion |
| Supply chain | pinned source/model revisions, license record, signed release provenance |

Benchmark results belong in [`benchmark-results.md`](benchmark-results.md);
criteria belong here or in
[`performance-acceptance.md`](performance-acceptance.md). Failed results remain
visible so future model or architecture changes can be compared honestly.
