# Language correction quality: SDD and TDD

**Status:** proposed implementation contract (no production implementation yet)

**Owner:** Language Correction Quality feature stream
**Scope:** local vocabulary, deterministic output replacements, quality evidence,
and the product truth for language support.

This document turns Slice 2 (Vocabulary and correction) and the language portion
of Slice 6 in the [product roadmap](product-roadmap.md) into an implementable,
testable contract. It does not change the current product claim.

## 1. Current facts and product truth

The current pipeline is intentionally narrow:

- `DictationSession.start()` and offline transcription always call
  `STTEngine.begin(language: nil, ...)`; the app therefore uses automatic/default
  model behavior and does not offer a language selection.
- The current `NemotronASRModel` streaming-session API accepts an optional
  `language` argument but silently falls back for an unrecognized value. The
  current Saymark Parakeet path uses its no-parameter generation call; the
  vendored default language value is only reported metadata and is not proven to
  constrain final decoding. Neither model reports an unsupported language. No
  code validates a model-supported language list, records language
  identification, or tests a selected language end to end.
- The shipped corpus is `saymark-english-v1`; it contains public English
  LibriSpeech audio only. It is useful evidence for English, not a general
  multilingual claim.
- In Live Preview, Nemotron creates an **automatic ASR draft** while recording;
  Parakeet replaces it after release. In Efficient mode, Parakeet creates only a
  final transcript. Neither path has a correction, vocabulary, learned-word, or
  spoken-edit-command processor today.

Accordingly, until separately promoted with fixtures and results:

| Product surface | Truthful state |
| --- | --- |
| Marketed/supported dictation language | English only, benchmarked by the versioned public English corpus. |
| Other-language transcription | Not claimed, not selectable, and not an experimental user-facing feature. |
| Automatic language detection | Not implemented or validated; do not display a detection result. |
| Manual language selection | Not implemented. A future selection may exist only for a model capability proven for both the draft and authoritative final path. |
| Translation | Out of scope. It must be an explicit future operation, never an implicit correction. |

The existing bare `AUTO` HUD language badge is not an acceptable product state:
it implies automatic language detection. The approved implementation must either
remove the badge or render `EN` while English is the sole supported language;
rename the UI model property so it is not called a detected language. No runtime
path may derive that string from model output. Product copy must not enumerate a
language count until every promoted language has a fixture manifest and an
accepted per-language result. Before any non-`auto` value is emitted to the
existing allowlisted `language` diagnostic field, it needs a dedicated privacy
review; the current field is logged publicly through OSLog.

## 2. Goals and non-goals

### Goals

1. Let a user locally define proper nouns, product terms, acronyms, preferred
   spelling/capitalization, and deterministic heard-to-write replacements.
2. Make the rendered transcript reproducible from the same raw ASR output, the
   same versioned ruleset, and the pinned Unicode/tokenization version.
3. Preserve raw ASR text for review, explicit user-initiated copy, metrics, and
   safe fallback.
4. Provide explicit import/export and a reversible migration path without
   sending vocabulary or transcripts off-device.
5. Measure correction quality independently from ASR quality and prevent a
   vocabulary improvement from masking a general-recognition regression.

### Non-goals

- No network model, cloud vocabulary synchronization, or remote correction.
- No background learning from dictated text, manual edits, active-app text,
  selected text, clipboard, or import data.
- No fuzzy matching, LLM rewrite, grammar/style rewriting, contextual guessing,
  phonetic inference, or automatic acronym expansion in the first release.
- Built-in spoken URL, email, and acronym normalization is deferred. Slice 2
  initially supports those forms only when the user adds an explicit alias; the
  roadmap records this deferral rather than implying a shipped built-in parser.
- No change to the ASR model weights or claim that a post-ASR replacement is
  model-native vocabulary biasing.
- No spoken semantic edit commands in this feature. “Replace the last word with
  …”, “delete that”, or “make it friendlier” are future command semantics, not
  an automatic ASR revision or deterministic replacement.

## 3. Architecture and data model

### 3.1 Processing boundary

Add a pure `TranscriptCorrectionPipeline` after each model produces text and
before a transcript is rendered, inserted, copied, or exported as corrected
text. It receives no microphone audio, accessibility text, clipboard contents,
or application context. It runs on model text before any output-exit decoration;
in particular, the in-field insertion path's appended trailing space is not part
of a matchable or replaceable span.

```text
audio -> ASR draft/final -> raw transcript -> deterministic correction -> rendered transcript
                              |                   |
                              |                   +-> counts-only diagnostics
                              +-> user-visible raw fallback / explicit copy
```

The source of authority remains unchanged:

- **Live Preview:** Nemotron automatically revises its own ASR hypothesis while
  audio arrives. The correction pipeline **MUST** correct and publish the newest
  non-superseded raw draft using one snapshot of the ruleset. It assigns monotonic hypothesis sequence
  numbers; if a newer draft arrives while a correction is pending, it supersedes
  the queued draft (latest-wins) rather than building a queue. A completed result
  may publish only if it is still the newest sequence, so visible output remains
  ordered. On release, Parakeet's raw final is corrected from scratch with the
  same snapshot; it replaces the draft as it does today. If Parakeet is empty,
  the Nemotron **raw** draft is corrected exactly once to form the
  `nemotron_fallback` final; it must never correct an already-rendered draft.
- **Efficient:** Parakeet's raw final is corrected once after release.
- **Never:** a correction rule feeds text back into ASR, changes audio, or
  attempts to interpret speech as a later semantic command.

Freeze the `VocabularySnapshot` at dictation start. A setting, import, deletion,
or enablement change during a dictation affects the *next* dictation only. This
prevents a displayed draft and the final text from being computed against
different rule sets merely because a settings window was open.

The raw and corrected forms must be separate values throughout the new boundary:

```swift
struct CorrectedTranscript: Sendable, Equatable {
    let rawText: String
    let renderedText: String
    let snapshotRevision: UInt64
    let appliedRuleCount: Int
}
```

This is an architectural shape, not a mandated public API. Neither value may be
written to diagnostics. Raw text is the fallback when correction evaluation or
loading fails; a rules failure must not suppress otherwise usable dictation.
If final correction fails after a successful draft correction, show/insert the
raw final and signal the correction failure without exposing content in logs.

### 3.2 Local storage

Use an app-private, atomic JSON document in Application Support with mode 0600.
The app is not sandboxed: this protects against other local users, not processes
running as the same macOS user. Do not use iCloud key-value storage,
`UserDefaults`, a model repository, or the diagnostic directory.

Version 1 logical document:

```json
{
  "schemaVersion": 1,
  "unicodeVersion": "15.1.0",
  "revision": 42,
  "entries": [
    {
      "id": "2D2E94E2-7C41-4A45-A2C5-B869F82632F3",
      "kind": "vocabulary",
      "written": "Saymark",
      "heard": ["say mark", "sagemark"],
      "enabled": true,
      "createdAt": "2026-07-26T00:00:00Z",
      "updatedAt": "2026-07-26T00:00:00Z"
    },
    {
      "id": "B7D12E55-2BA7-4E37-A6D9-4CC9D97B2B1B",
      "kind": "replacement",
      "written": "https://saymark.app",
      "heard": ["say mark dot app"],
      "enabled": true,
      "createdAt": "2026-07-26T00:00:00Z",
      "updatedAt": "2026-07-26T00:00:00Z"
    }
  ]
}
```

`written` is exactly the desired output, including case, punctuation, and
Unicode. Every `heard` item is an explicit ASR-output phrase, not an acoustic
pronunciation model. A vocabulary entry and a replacement entry have the same
deterministic matching behavior in v1; their distinct kinds make the user intent
and future UI clear. A single entry may include several explicit aliases.

Entry validation:

- IDs are UUIDs; they are stable across export/import when an import is merged.
- `written` and each `heard` phrase are non-empty after trim and are bounded to
  256 Unicode scalar values; an entry has 1–16 aliases and no duplicate alias.
- An alias may not yield an empty `matchKey`, nor may the document contain two
  enabled aliases with the same `matchKey`. Reject that
  ambiguous change with a user-visible, actionable conflict; do not choose a
  winner silently.
- The document is bounded to 5,000 enabled/disabled entries and 20,000 aliases.
  Imports exceeding either bound fail transactionally.
- `written` and aliases reject C0/C1 controls, bidi overrides/isolates,
  default-ignorable code points, and unassigned code points. This prevents a
  value that displays differently from what insertion delivers.
- Unknown document fields are preserved only if a future migration explicitly
  supports them; v1 exporters emit only the documented fields. Unknown schema
  versions are never overwritten.

### 3.3 Normalization, matching, ordering, and conflicts

Matching must be locale-independent and deterministic under a pinned Unicode
implementation. The implementation must vendor fixed Unicode 15.1.0 NFKC,
default-case-folding, and UAX #29 word-boundary data rather than call the host
macOS ICU. `unicodeVersion` is part of every vocabulary document and corpus
fixture; a store with an unsupported version opens read-only and is not silently
reinterpreted. Golden tests are a manual reference-machine release gate on the
supported macOS 15 (deployment target) and macOS 26 matrix; they are not claimed
as current single-runner CI coverage.

`matchKey(_:)` is the one canonical function used by validation and matching:
NFKC, default case fold, whitespace-run collapse to one ASCII space, trim, then
tokenization using the pinned UAX #29 data. It never strips diacritics,
transliterates, stems, singularizes, or uses edit distance. A token-level
Aho-Corasick automaton makes matching bounded rather than scanning every alias.

The normalizer returns a provenance-aligned key, not a string alone. Every
emitted match-key scalar carries the closed range of original Unicode scalar
offsets that contributed to it; when normalization composes or expands adjacent
scalars, their ranges are unioned. For a matched run, the replacement span is
the union from the first matched key scalar's source range through the last's,
including intervening original scalars. A candidate match that begins or ends
inside one original scalar's compatibility expansion is rejected: expansions are
atomic. Thus alias `株` does not replace the middle token of `㈱ -> (株)`, and
alias `株式` does not replace part of `㍿ -> 株式会社`. This defines replacement for
length-changing forms such as `ﬁ -> fi`, `ß -> ss`, `㍿ -> 株式会社`, and NFC/NFD-
equivalent accented sequences without indexing the original string by match-key
offsets.

Scan token positions left to right. At a position choose the longest complete
token-sequence match; unique `matchKey` values eliminate equal-length ties.
Continue after the consumed span and never reprocess output. A hyphen is a token
delimiter, so alias `foo` matches `foo-bar`; an apostrophe joins the word token,
so alias `mark` does not match `mark's`. These boundary cases are fixtures, not
dependent on host tokenizer behavior.

Examples:

| Raw ASR text | Rules | Rendered text |
| --- | --- | --- |
| `open say mark dot app` | `say mark dot app -> https://saymark.app` | `open https://saymark.app` |
| `say mark announced say mark` | `say mark -> Saymark` | `Saymark announced Saymark` |
| `catalog` | `cat -> Cat` | `catalog` (no substring replacement) |
| `foo bar` | `foo -> X`; `foo bar -> Y` | `Y` (longest match) |
| `foo` | `foo -> bar`; `bar -> baz` | `bar` (single pass; no cascade) |

All mutation validates the normalized-trigger uniqueness invariant. Disabled
rules are excluded from matching and may conflict with each other; enabling one
must run the same conflict check. Matching must not depend on insertion order,
storage order, device locale, time, or active application.

### 3.4 Model-native biasing adapter

Define a separate, optional capability boundary for a future model-native
vocabulary/prompt/bias feature. It must report an explicit capability enum and
be independently benchmarked. The current pinned Nemotron/Parakeet integration
provides no checked-in proof of a safe, end-to-end vocabulary-bias API, so v1
uses only post-ASR deterministic replacement and must say so in its UI.

An adapter may be enabled only when all are true:

- the active draft *and* authoritative-final model path exposes the capability;
- a language selection validates against the pinned Nemotron prompt dictionary
  and an end-to-end fixture proves the authoritative Parakeet final path honors
  it; Saymark rejects an unsupported value before either model can fall back;
- the model revisions, API semantics, size limits, and language behavior are
  pinned and documented;
- the vocabulary corpus proves the advertised gain and the general corpus passes
  its regression gate; and
- the privacy review confirms values stay local unless the user explicitly
  approves a separately described network path.

There is no fallback that pretends to bias a model. If unavailable, the explicit
post-ASR result is the behavior.

## 4. User behavior, import/export, and migration

### 4.1 User controls

The feature needs a local Vocabulary & Replacements settings surface with
search, add, edit, enable/disable, delete, import, export, and a way to reveal
the raw transcript where corrected output is shown. Add/edit requires a written
value and one or more “heard as” aliases. A preview must show supplied sample
ASR text and the exact deterministic result, plus a conflict before save.

No setting means no rules. New installs start with an empty store. The app must
never infer a rule from a correction the user made elsewhere, a frequently seen
word, an imported transcript, or a previously recognized phrase. The only
automatic change allowed is a schema migration that preserves existing explicit
records and records no speech content.

### 4.2 Import/export

Export is an explicit save-panel action that writes the versioned JSON document
above. It is user data: show that it may include names and other sensitive terms.
Do not export transcripts, audio, diagnostics, settings unrelated to this
feature, active-app data, or analytics identifiers.

Import is an explicit open-panel action with a validation/preview step:

- read only a regular, non-symlink file using a descriptor opened before checks;
  reject a directory, FIFO/device, unreadable file, malformed JSON, unsupported
  schema, unsupported `unicodeVersion`, duplicate IDs, invalid bounds, or a read that exceeds 5 MiB. Enforce
  the byte cap while reading and pre-scan JSON nesting depth before Foundation
  decoding; `JSONDecoder` does not provide a safe depth limit itself;
- validate the imported document internally first. Then reconcile it with the
  local store for the chosen action: Merge rejects `matchKey` collisions against
  retained local entries; Replace all checks only the imported result;
- show counts for new, unchanged, updated, disabled, and conflicting entries
  **and** an entry-by-entry old-to-new diff for every update/replacement. Flag
  each written value containing a URL scheme and require acknowledgement before
  Merge applies a replacement;
- require the user to choose **Merge by ID** or **Replace all**. Default to
  Merge; Replace all needs destructive confirmation;
- do not mutate storage until the complete file validates and confirmation is
  received; a cancellation leaves the store byte-for-byte unchanged;
- on ID collision, Merge uses the imported record only after the preview states
  it will replace the local record. No timestamp-based silent winner.

### 4.3 Migration and recovery

The storage loader must identify schema version before decoding entries. A known
older schema is migrated in memory and validated. Write the verified primary to
a temporary same-directory file with mode 0600, fsync it, rotate the prior primary
to the last-known-good backup, atomically replace the primary, then fsync the
directory. Retain the backup until the next successful load; do not log its
contents. Implement this as a shared durable-store helper rather than duplicating
slightly different atomic-write semantics. An unknown newer schema opens in
read-only/export-safe mode with an explanation and no overwrite.

If a known store is corrupt, preserve the original for manual recovery, create
an empty in-memory ruleset for dictation, and show a recovery action to export or
locate the retained file. Correction failures always fall back to raw ASR text;
they must not block insertion or delete the user's vocabulary.

## 5. Quality measurement and release gates

### 5.1 Metrics

For each dictated utterance calculate metrics from in-memory test/benchmark
material; production diagnostics may store only the allowed counts and rates.

| Metric | Definition | Required reporting |
| --- | --- | --- |
| Raw ASR WER | Existing normalized WER between reference and model raw final. | Macro, scenario, and per promoted language. |
| Rendered WER | Existing normalized WER on the rendered hypothesis against the human-authored intended written reference. The reference is never rule-transformed. | Regression guard only; it is case/punctuation-insensitive and never the benefit metric. |
| Target-term surface error rate | Incorrect/missing exact annotated intended spans, including case and punctuation, divided by the manifest-pinned target occurrence denominator. | Per term category/language, with confidence interval. |
| False-replacement rate | Incorrect replacements divided by the manifest-pinned eligible negative occurrences. | Global and per rule category. |
| Corrected provisional-to-final divergence | Token edit distance and normalized word distance between corrected draft and corrected final. Existing raw divergence fields retain their present raw semantics. | Live Preview, aggregate only in diagnostics. |
| Revoked words per second | Total words removed/replaced across consecutive automatic ASR draft revisions divided by voiced seconds reported by the pinned VAD version/threshold in the fixture. | Live Preview long and short fixtures. |
| Long-dictation stability | Maximum revision depth, maximum no-update interval, divergence, revokes/sec, and final correctness on 30–120 second fixtures. | Each long fixture and aggregate. |
| Correction latency | Time from raw transcript availability to corrected rendered result. | p50/p95/max. |

“Revoke” is an automatic change between two successive ASR hypotheses. It is
not a later spoken semantic edit command, user typing, or a rule changed during
dictation. Count the minimum word-level delete/replace operations between
successive rendered drafts, with one correction snapshot for the whole
dictation.

### 5.2 Corpus policy

Keep the current English public corpus as the ASR baseline. Corpus schema must
bump from v2 before adding correction fields, use BCP-47 locale tags rather than
display labels, pin `unicodeVersion`, correction snapshot revision, target spans,
negative denominator, split identity, and expected rendered output. Results, not
manifests, record model repository/revision. Add separately versioned,
redistributable or explicitly consented fixtures before promotion:

- an English vocabulary corpus with proper nouns, companies/products, acronyms,
  URL/email-like explicit aliases, capitalization, punctuation, repeated terms,
  negative substring cases, and ambiguous-looking near misses;
- a development/evaluation split where vocabulary aliases are authored and frozen
  before transcription of the held-out evaluation clips; report confidence
  intervals, not a post-hoc score; and
- for a language promotion, the same scenario coverage as English, multiple
  speakers, sufficient total duration and reference word count to report a WER
  confidence interval, plus a language-specific rule/negative fixture. Five
  clips are smoke coverage only, never promotion evidence; and
- word-timestamped Live Preview fixtures sufficient to measure visible stability
  and revision behavior without recording private production audio.

Never commit private user vocabulary or recordings. The Live Preview streaming
harness and timestamped fixtures are new prerequisites: the current offline
corpus runner cannot measure draft order, correction queueing, revokes, or
visible stability.

### 5.3 Acceptance criteria

The roadmap remains the authoritative home for existing Slice 2 and Slice 6
gates. The following are new feature-specific gates or explicit qualifications:

| Gate | Acceptance criterion |
| --- | --- |
| English model truth | Existing public corpus passes raw macro/scenario/locale WER gates. |
| Vocabulary benefit | Held-out target-term surface error rate has at least 50% relative reduction versus raw ASR, with its confidence interval and frozen development split recorded. |
| General accuracy | Raw general-corpus macro WER regresses no more than 0.5 absolute percentage points. This is new work; baseline comparison must fail for a missing scenario/locale key rather than silently skip it. |
| False replacements | <= 1% across versioned negative fixtures, with zero substring or cascade replacements. |
| Latency | Per-draft correction p95 <= 10 ms and max <= 25 ms inside the hypothesis-to-mutation budget; final-only correction p95 <= 100 ms. Live updates are latest-wins with zero correction backlog. |
| Long dictation | All 30–120 second fixtures complete with bounded memory, ordered updates, no visible freeze > 300 ms, and recorded divergence/revokes metrics. No threshold for revokes is promoted until a baseline exists; any material regression requires review. |
| Per-language promotion | Each language has evidence described in section 5.2, raw macro WER <= 8%, no scenario regression > 1 absolute point, LID >= 98% on fixtures >= 5 seconds if detection is offered, and documented/tested code-switch handling that is never advertised when unsupported. Selection must validate against Nemotron's prompt dictionary and prove the authoritative final path honors it; Saymark rejects unsupported values rather than relying on either model's fail-open behavior. |
| Privacy | No audio, transcript, vocabulary trigger/written value, corrected output, app text, clipboard, filename, or stable identifier occurs in logs or telemetry. |

## 6. Privacy and security model

Vocabulary values can be as sensitive as transcripts (names, internal products,
and URLs). Treat the vocabulary store, import, and export as sensitive local
data.

| Asset/boundary | Requirement |
| --- | --- |
| Vocabulary store | Local 0600 file; atomic durable writes; no cloud sync, analytics, model prompt, or diagnostics. It is not protected from another process running as the same user. |
| Raw/corrected transcript | Memory only for normal dictation; never diagnostic fields, OSLog values, telemetry, crash metadata, or import/export payload. |
| Import | Explicit user action; bounded/validated untrusted JSON; no parsing side effects before validation. |
| Export | Explicit user-selected destination; warn that it contains sensitive terms; no automatic sharing. |
| Rules engine | Pure, bounded, single-pass algorithm; no regex supplied by users, recursion, network, or active-app/clipboard access. |
| Local correction diagnostics | Off by default behind a new `CorrectionDiagnosticsConsent` control, separate from `AnalyticsConsent`/PostHog. It is local JSONL only and explicitly excluded from every PostHog capture. Aggregate exactly one rolling batch of 100 completed dictations with no session ID, emit only a bucket of `0`, `1-9`, or `10+`, then discard/reset the batch; never emit per-utterance counts (a content oracle), rule IDs, or string values. Do not reuse generic existing allowlist names such as `reason`, `source`, or `revision` for correction data. |
| Future model bias | Separate threat/privacy review because vocabulary would cross a model API boundary even if local. |

Security tests must fuzz Unicode and malformed imports, prove transactional
failure, validate file-size and count limits, and run a value-level
forbidden-content scan seeded from active rule values over every diagnostic event.
Correction diagnostic fields are numeric only; new fields require explicit
allowlisting and a privacy test. A generic dictionary or serialized ruleset is
prohibited.

## 7. Accessibility and UI/design approval

The following requires user design approval before implementation. No mockup is
included in this phase.

| Decision needing approval | Minimum mockup |
| --- | --- |
| Vocabulary settings information architecture, list density, terminology, and whether “Vocabulary” and “Replacements” are one section or separate tabs. | One Settings window state with empty, populated/search, and add/edit sheet states. |
| Rule-editor labels and preview treatment, including how an exact match is explained without suggesting acoustic learning. | Editor with written value, several heard-as aliases, preview input/result, validation error, and conflict state. |
| Display/recovery of raw ASR text beside corrected text, including whether it is inline, disclosure, copy action, or post-dictation HUD affordance. | HUD/final-result state showing corrected output, raw fallback, Nemotron-fallback final that differs from draft, and keyboard focus order. |
| Import merge/replace flow, destructive confirmation, conflict resolution, and sensitive-data warning. | Import summary with valid, invalid, conflict, Merge, Replace all, cancel, confirmation, and per-entry old-to-new/URL acknowledgement states. |
| Language truth presentation: removal of `AUTO` or its exact replacement by `EN`, an unsupported-language state, and a future selection affordance. | Current HUD/Settings English state plus an unsupported/experimental explanatory state. |
| Accessibility wording and error presentation. | VoiceOver focus order/labels and full-keyboard traversal annotations for list, editor, preview, and import sheet. |

Implementation must use native SwiftUI/AppKit controls, respect Dynamic Type and
increased contrast, expose clear VoiceOver labels/hints and validation messages,
support full keyboard operation, avoid color-only states, and keep sensitive
terms out of accessibility identifiers and test logs. Screen-reader users must
be able to review the exact written and heard-as strings locally; that visibility
does not authorize them to enter diagnostics.

## 8. Test-driven delivery plan

Each slice starts with the listed failing test/fixture. Production code follows
only when its tests and user-approved UI are ready.

### Slice A — Pure correction core and storage

1. Add `VocabularyEntry`, document validator, normalization/tokenization, and
   immutable snapshot tests.
2. Add leftmost-longest, single-pass correction tests and property/fuzz tests.
3. Add local store atomic-write, migration, corruption recovery, and bounded
   import parser tests.

### Slice B — Controlled integration and diagnostics

1. Introduce the correction boundary to final and live update paths behind an
   empty-by-default store.
2. Capture one snapshot at dictation start; prove mid-session changes defer.
3. Add separately consented local-only, rolling-100-dictation diagnostics plus
   value-level forbidden-content inspection tests.
4. Build the Live Preview streaming harness before adding benchmark result types;
   it must capture hypothesis sequence, VAD provenance, latest-wins supersession,
   and timestamped vocabulary/long-dictation fixtures.

### Slice C — Approved settings, accessibility, import/export

1. Obtain the mockups listed above and write XCUITests from them.
2. Implement native management, preview, raw fallback, import/export, and
   destructive confirmation.
3. Run keyboard, VoiceOver, privacy, and recovery paths in UI tests.

### Slice D — Evidence and language promotion

1. Run the versioned English vocabulary/general/long corpus on the reference
   Apple-silicon machines and record all required metadata.
2. Do not add a language selection/detection control until a capability registry,
   per-language fixtures, and acceptance results exist.
3. Promote a language only by updating product documentation and UI in the same
   reviewed change as its accepted evidence.

## 9. Exhaustive test requirements

Test IDs are normative requirements and implementation test names use the
corresponding prefix (for example, `test_U23_spanReplacement...`). Pure unit,
diagnostic privacy, storage-security, and architecture-boundary tests are
CI-blocking. The U-23 cross-macOS Unicode golden matrix is a manual macOS 15/26
reference-machine release gate. Real-model corpus, performance, streaming-
harness, and XCUITest evidence are opt-in reference-machine release gates until
CI infrastructure is explicitly added; their required reports attach to the
PR/release evidence.

### Unit tests

| ID | Case | Expected assertion |
| --- | --- | --- |
| U-01 | Empty rules and arbitrary raw text | Rendered text equals raw text; zero applied rules. |
| U-02 | Proper noun aliases with case variants | Exact canonical `written` output replaces complete aliases. |
| U-03 | NFKC-equivalent alias/input | Same deterministic match without changing unmatched original text. |
| U-04 | Whitespace runs/newlines around an alias | Match occurs; only the replaced span uses the written output. |
| U-05 | Alias inside a longer word | No replacement. |
| U-06 | Punctuation adjacent to alias | Correct boundary behavior for opening/closing punctuation and apostrophes. |
| U-07 | Overlapping short/long aliases | Leftmost-longest result, independent of entry insertion order. |
| U-08 | Output that is another trigger | Single-pass result; no cascade. |
| U-09 | Repeated aliases | Every non-overlapping occurrence is replaced in order. |
| U-10 | Non-ASCII/combining characters and emoji near rules | No crash, deterministic result, no lossy unmatched-text rewrite. |
| U-11 | Duplicate normalized enabled trigger | Create/edit/enable rejected with conflict identity; store unchanged. |
| U-12 | Disabled conflicting rule | It does not apply; enabling it is rejected if it conflicts. |
| U-13 | Invalid IDs, bounds, blank values, duplicate aliases | Validator rejects each exact reason. |
| U-14 | 5,000 entries/20,000 aliases boundary | Boundary accepted; one-over rejected without partial mutation. |
| U-15 | Snapshot isolation | Mutating store after snapshot cannot alter its result. |
| U-16 | Randomized rule order and randomized nonmatching Unicode input | Result is invariant and completes within bounded time. |
| U-17 | Malformed/oversized/deep JSON imports | Rejected before store mutation and without resource blowup. |
| U-18 | Import merge ID collision / Replace all / cancel | Explicit chosen outcome only; cancel leaves bytes unchanged. |
| U-19 | Known migration, incompatible Unicode, and unknown future schema | Known schema atomically migrates; unsupported `unicodeVersion` and future schema are read-only/no overwrite. |
| U-20 | Interrupted write/corrupt primary | Last-known-good recovery is offered; dictation receives empty snapshot/raw fallback. |
| U-21 | Metrics token edits | Divergence and revokes/sec calculations match annotated sequences. |
| U-22 | No semantic-command interpretation | “replace foo with bar” remains raw/corrected only by an explicit matching rule. |
| U-23 | Provenance span alignment and expansion atomicity | `ﬁ`, `ß`, `㍿`, and NFC/NFD accent forms replace the correct original scalar span; `㈱` with alias `株` does not partially replace the expansion. |
| U-24 | Case-fold collision | `Foo` after `foo` is rejected at create, edit, and enable. |
| U-25 | Unsafe Unicode | Written/alias control, bidi override/isolate, default-ignorable, and unassigned scalars are rejected. |
| U-26 | Reconciliation collision | Alias collision with local store is rejected under Merge and evaluated only in imported result under Replace all. |
| U-27 | Concurrent snapshot/store access | A dictation-held snapshot remains immutable while settings writes/imports commit atomically. |

### Integration and model tests

| ID | Case | Expected assertion |
| --- | --- | --- |
| I-01 | Efficient final with an enabled alias | Correction runs after Parakeet final and before insertion/HUD output. |
| I-02 | Live Preview sequence then Parakeet final | Every draft and final uses one frozen snapshot; final retains final-model authority. |
| I-03 | Empty/failing correction snapshot | Raw transcript remains visible/insertable; pipeline does not fail dictation. |
| I-04 | Rule edit/import while recording | Current session remains unchanged; next session uses new revision. |
| I-05 | Existing English public corpus without rules | Raw and rendered WER are identical and existing acceptance remains green. |
| I-06 | Versioned vocabulary corpus and baseline | Target-term/false-replacement metrics emit expected values; a missing scenario or locale baseline key fails rather than silently skipping regression. |
| I-07 | Existing `long-30s/45s/60s/90s/120s` streaming fixtures | Ordered updates, bounded memory, raw and corrected divergence/revokes calculation, no dropped final, and zero correction backlog. |
| I-08 | Candidate non-English fixture before promotion | Report only; no supported-language claim or selection behavior changes. |
| I-09 | Future selected-language adapter contract | Fails closed unless both draft/final support and fixture validation are declared. |
| I-10 | Model-native bias adapter unavailable | Post-ASR rules still work; UI/API does not claim model biasing. |
| I-11 | Nemotron fallback with `foo -> bar`, `bar -> baz` | `final_source == nemotron_fallback` corrects raw `foo` once to `bar`, never `baz`. |
| I-12 | Draft arrival exceeds correction throughput | Latest draft supersedes pending work; no backlog or out-of-order publication. |
| I-13 | Final correction fails after corrected draft | Raw final is shown/inserted with content-free error signal. |

### UI and accessibility tests (after approval)

| ID | Case | Expected assertion |
| --- | --- | --- |
| UI-01 | Empty settings state | Explains explicit local rules; no suggestion of automatic learning. |
| UI-02 | Add/edit/disable/delete/search | Native controls update visible state and persist across relaunch. |
| UI-03 | Rule preview and conflict | Preview is deterministic; save is blocked with an accessible conflict message. |
| UI-04 | Keyboard-only traversal | All list/editor/preview/import controls reachable, ordered, and operable. |
| UI-05 | VoiceOver | Labels distinguish written output from heard-as aliases; errors announced once. |
| UI-06 | Corrected final and raw fallback | User can identify/copy the intended text without ambiguity. |
| UI-07 | Import preview/cancel/merge/replace | Counts, per-entry diffs, URL acknowledgement, and destructive confirmation match the approved mockup; cancel changes nothing. |
| UI-08 | Dynamic Type, contrast, reduced motion | No clipped values or color-only validation; no new distracting animation. |
| UI-09 | Language truth | `AUTO` is absent; `EN` or no badge matches the approved mockup, no unsupported language appears selectable/detected, and no label comes from model output. |

### Performance, reliability, and security tests

| ID | Case | Expected assertion |
| --- | --- | --- |
| P-01 | 5,000 entries/20,000 aliases, ordinary final | Final-only correction p95 <= 100 ms; no main-thread work. |
| P-02 | Long live dictation under maximum rule set | Latest-wins zero-backlog behavior and existing update/stop-to-final/memory gates remain satisfied. |
| P-03 | 20 consecutive sessions | No retained snapshots, file handles, subscriptions, or unbounded memory growth. |
| P-04 | Maximum rules at live draft cadence | Per-draft correction p95 <= 10 ms, max <= 25 ms inside hypothesis-to-mutation budget. |
| S-01 | Diagnostic event capture at every level | No raw/corrected text, vocabulary value, rule ID, filename, clipboard, app text, or audio appears; test is CI-blocking. |
| S-02 | Allowlist mutation attempt | Unknown diagnostic field is discarded; new aggregate fields require explicit tests. |
| S-03 | Import adversarial corpus | Size/depth/count limits, unsupported `unicodeVersion`, invalid/unsafe Unicode, duplicate keys, symlink/path cases, and failed atomic writes are safe. |
| S-04 | Export destination and content inspection | Only documented vocabulary document is written after explicit action. |
| S-05 | Network monitor during all vocabulary flows | Zero network requests. |
| S-06 | Permission boundary | Vocabulary management never requests microphone, Accessibility, screen, clipboard, or network permission. |
| S-07 | Value-level diagnostics scan and aggregation unit | Seed scan from active aliases/written values proves no correction content appears under any existing/new allowlisted field; exactly one local, no-session-ID bucket is emitted per 100-dictation batch and never reaches PostHog. |
| S-08 | Local-file permissions | Vocabulary primary, backup, temporary, and export files are mode 0600. |
| S-09 | Import read hardening | Depth pre-scan, FIFO/device rejection, descriptor identity, and read-time byte cap defeat malformed/TOCTOU inputs. |
| A-01 | Correction architecture boundary | Dependency/source assertion proves `TranscriptCorrectionPipeline` has no audio, Accessibility, clipboard, network, or diagnostics-string dependency. |

## 10. Requirements-to-tests traceability

| Requirement | Primary tests | Acceptance evidence |
| --- | --- | --- |
| Honest English-only language truth | I-08, I-09, UI-09 | Per-language corpus manifest and accepted result before promotion. |
| Explicit proper-noun vocabulary | U-01–U-10, U-13–U-14, I-06, UI-01–UI-03 | Held-out vocabulary target-term report. |
| Deterministic replacements | U-03–U-12, U-16, U-23–U-24 | Pinned-Unicode golden fixtures and randomized-order property test. |
| No silent learning or semantic commands | U-22, UI-01, UI-09, S-05 | Source review and network/permission test. |
| Snapshot consistency | U-15, I-02, I-04 | Live sequence fixture. |
| Raw fallback and final authority | I-01–I-03, I-11–I-13, UI-06 | Efficient and Live Preview integration run. |
| Import/export and safe migration | U-17–U-20, U-25–U-27, UI-07, S-03–S-04, S-08–S-09 | Recovery and transaction test report. |
| Correction quality | U-21, I-05–I-07, I-12, P-01–P-04 | Versioned streaming/model corpus report with raw, corrected, surface, and confidence metrics. |
| Privacy/security | S-01–S-09, A-01 | CI diagnostics scan, network monitor, architecture, and adversarial import report. |
| Future model-native adapter | I-09–I-10 | Capability evidence for both model paths and privacy review. |
| Accessible approved UI | UI-04–UI-09 | XCUITest plus manual VoiceOver verification against mockup. |

## 11. Open questions and risks

1. **Language evidence:** Verify the pinned model cards/API behavior under the
   exact revisions before any language capability registry is introduced. The
   current source alone proves neither a supported-language list nor language
   identification quality.
2. **Normalization implementation:** Unicode 15.1.0 is the required contract;
   select and vendor the Swift implementation/table set before Slice A. There is
   no established pure-Swift dependency known to provide pinned NFKC, full case
   folding, and UAX #29 *word* segmentation together; Swift standard library
   grapheme breaking is insufficient. Size/build-or-source that dependency and
   its table update policy before committing implementation. Add golden tests
   before treating its NFKC/case-folding behavior as compatible.
3. **Raw-text retention UX:** Decide where raw ASR is exposed and for how long;
   do not quietly create transcript history while implementing the fallback.
4. **Import interoperability:** Decide whether the v1 JSON schema is public and
   stable at launch or marked preview. The answer controls compatibility and
   unknown-field preservation policy.
5. **Ambiguous natural speech:** Exact aliases cannot reliably resolve all
   proper nouns. Avoid marketing them as pronunciation training until a
   model-native bias capability passes the separate evidence gate.
6. **UI approval:** The six mockup categories in section 7, including the
   English badge, fallback final, and per-entry import diff, need user approval
   before any Settings/HUD/import surface is implemented.
7. **Correction-versus-insertion interaction:** The live-insertion feature must
   consume only the rendered text it owns, retain its ownership safety contract,
   and never treat a correction as permission to overwrite user text.
