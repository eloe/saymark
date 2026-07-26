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
  `language` argument. The current `ParakeetModel.generate` final pass does not
  receive a language argument. No code validates a model-supported language
  list, records language identification, or tests a selected language end to
  end.
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

The existing HUD badge may continue to show “Auto” as a pipeline state, but it
must not be described as language detection. Product copy must not enumerate a
language count until every promoted language has a fixture manifest and an
accepted per-language result.

## 2. Goals and non-goals

### Goals

1. Let a user locally define proper nouns, product terms, acronyms, preferred
   spelling/capitalization, and deterministic heard-to-write replacements.
2. Make the rendered transcript reproducible from the same raw ASR output and
   the same versioned ruleset.
3. Preserve raw ASR text for review, export, metrics, and safe fallback.
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
or application context.

```text
audio -> ASR draft/final -> raw transcript -> deterministic correction -> rendered transcript
                              |                   |
                              |                   +-> counts-only diagnostics
                              +-> user-visible raw fallback / export
```

The source of authority remains unchanged:

- **Live Preview:** Nemotron automatically revises its own ASR hypothesis while
  audio arrives. The correction pipeline may render each supplied draft using a
  snapshot of the ruleset. On release, Parakeet's raw final is corrected from
  scratch with the same snapshot; it replaces the draft as it does today.
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

### 3.2 Local storage

Use an app-private, atomic JSON document in Application Support protected by
normal macOS user-file permissions. Do not use iCloud key-value storage,
`UserDefaults`, a model repository, or the diagnostic directory. The exact
location and file-protection behavior must be documented with the implementation.

Version 1 logical document:

```json
{
  "schemaVersion": 1,
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
- An alias may not normalize to the same empty value, nor may the document
  contain two enabled aliases with the same normalized trigger. Reject that
  ambiguous change with a user-visible, actionable conflict; do not choose a
  winner silently.
- The document is bounded to 5,000 enabled/disabled entries and 20,000 aliases.
  Imports exceeding either bound fail transactionally.
- Unknown document fields are preserved only if a future migration explicitly
  supports them; v1 exporters emit only the documented fields. Unknown schema
  versions are never overwritten.

### 3.3 Normalization, matching, ordering, and conflicts

Matching must be locale-independent and deterministic. The correction engine
has two forms for each input: an immutable original string used to preserve
unmatched text, and a match key used only to locate explicit aliases.

1. Normalize both raw transcript and each alias with Unicode NFKC.
2. Treat each maximal Unicode whitespace run as one match-key space; trim only
   for matching. Preserve original whitespace except in a replaced span.
3. Tokenize the match key using Unicode word-boundary rules. A phrase may match
   only complete token sequences, never a substring of a longer token.
4. Match aliases case-insensitively using Unicode default case folding. Do not
   strip diacritics, transliterate, stem, singularize, or use edit distance.
5. At each leftmost position choose the longest token-sequence match. Because
   normalized triggers are unique, this produces one result. Continue after the
   consumed span; never re-process replacement output.
6. Replace that original span with `written` exactly. Output punctuation,
   whitespace, and capitalization therefore come only from explicit user data.

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

- parse a regular file only; reject a directory, symlink escaping the selected
  file, unreadable file, malformed JSON, unsupported schema, duplicate IDs,
  invalid bounds, and normalized-trigger collisions;
- show counts for new, unchanged, updated, disabled, and conflicting entries;
- require the user to choose **Merge by ID** or **Replace all**. Default to
  Merge; Replace all needs destructive confirmation;
- do not mutate storage until the complete file validates and confirmation is
  received; a cancellation leaves the store byte-for-byte unchanged;
- on ID collision, Merge uses the imported record only after the preview states
  it will replace the local record. No timestamp-based silent winner.

The initial implementation must limit file size before decoding (for example,
5 MiB) and decode with depth/entry limits to avoid resource exhaustion.

### 4.3 Migration and recovery

The storage loader must identify schema version before decoding entries. A known
older schema is migrated in memory, validated, then atomically written using a
temporary sibling file and rename. Retain one last-known-good backup until the
next successful load; do not log its contents. An unknown newer schema opens in
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
| Rendered WER | WER after applying the versioned ruleset to both reference and hypothesis where the fixture declares that ruleset. | Vocabulary corpus only; never substitute for raw WER. |
| Target-term error rate | Incorrect/missing target occurrences divided by annotated target occurrences. | Per term category and language. |
| False-replacement rate | Incorrect replacements divided by eligible negative occurrences. | Global and per rule category. |
| Provisional-to-final divergence | Existing token edit distance and normalized word distance between corrected draft and corrected final, plus raw values for diagnosis. | Live Preview, aggregate only in diagnostics. |
| Revoked words per second | Total words removed/replaced across consecutive automatic ASR draft revisions divided by voiced seconds. | Live Preview long and short fixtures. |
| Long-dictation stability | Maximum revision depth, maximum no-update interval, divergence, revokes/sec, and final correctness on 30–120 second fixtures. | Each long fixture and aggregate. |
| Correction latency | Time from raw transcript availability to corrected rendered result. | p50/p95/max. |

“Revoke” is an automatic change between two successive ASR hypotheses. It is
not a later spoken semantic edit command, user typing, or a rule changed during
dictation. Count the minimum word-level delete/replace operations between
successive rendered drafts, with one correction snapshot for the whole
dictation.

### 5.2 Corpus policy

Keep the current English public corpus as the ASR baseline. Add separately
versioned, redistributable or explicitly consented fixtures before promotion:

- an English vocabulary corpus with proper nouns, companies/products, acronyms,
  URL/email-like explicit aliases, capitalization, punctuation, repeated terms,
  negative substring cases, and ambiguous-looking near misses;
- at least 5 clips per proposed additional language, including a language-specific
  rule/negative fixture and a long fixture where practical; and
- word-timestamped Live Preview fixtures sufficient to measure visible stability
  and revision behavior without recording private production audio.

Never commit private user vocabulary or recordings. Corpus manifests pin source,
license/consent, transcript/reference, checksum, model revision, correction
snapshot revision, and expected render output. Do not manufacture a target-term
score by applying the user rules to model references without also reporting raw
ASR WER.

### 5.3 Acceptance criteria

In addition to all existing performance and privacy gates:

| Gate | Acceptance criterion |
| --- | --- |
| English model truth | Existing public corpus passes raw macro/scenario/locale WER gates. |
| Vocabulary benefit | Target-term error rate has at least 50% relative reduction versus raw ASR on the declared vocabulary corpus. |
| General accuracy | Raw general-corpus macro WER regresses no more than 0.5 absolute percentage points; existing model-promotion limit remains applicable where stricter. |
| False replacements | <= 1% across versioned negative fixtures, with zero substring or cascade replacements. |
| Latency | Added correction p95 <= 100 ms and no existing stop-to-final or live-update budget regresses. |
| Long dictation | All 30–120 second fixtures complete with bounded memory, ordered updates, no visible freeze > 300 ms, and recorded divergence/revokes metrics. No threshold for revokes is promoted until a baseline exists; any material regression requires review. |
| Per-language promotion | Each language has its own public/consented manifest, >= 5 clips, raw macro WER <= 8%, no scenario regression > 1 absolute point, and validated detection/selection behavior if offered. |
| Privacy | No audio, transcript, vocabulary trigger/written value, corrected output, app text, clipboard, filename, or stable identifier occurs in logs or telemetry. |

## 6. Privacy and security model

Vocabulary values can be as sensitive as transcripts (names, internal products,
and URLs). Treat the vocabulary store, import, and export as sensitive local
data.

| Asset/boundary | Requirement |
| --- | --- |
| Vocabulary store | App-private local file; atomic writes; no cloud sync, analytics, model prompt, or diagnostics. |
| Raw/corrected transcript | Memory only for normal dictation; never diagnostic fields, OSLog values, telemetry, crash metadata, or import/export payload. |
| Import | Explicit user action; bounded/validated untrusted JSON; no parsing side effects before validation. |
| Export | Explicit user-selected destination; warn that it contains sensitive terms; no automatic sharing. |
| Rules engine | Pure, bounded, single-pass algorithm; no regex supplied by users, recursion, network, or active-app/clipboard access. |
| Diagnostics | Permit aggregate `correction_rule_count`, `correction_applied_count`, divergence/revoke counts, and timings only after allowlist review. Prohibit rule IDs if stable across sessions and all string values. |
| Future model bias | Separate threat/privacy review because vocabulary would cross a model API boundary even if local. |

Security tests must fuzz Unicode and malformed imports, prove transactional
failure, validate file-size and count limits, and inspect every allowed
diagnostic field/event for forbidden values. Add new diagnostic field names only
through the existing explicit allowlist and a privacy test; a generic dictionary
or serialized ruleset is prohibited.

## 7. Accessibility and UI/design approval

The following requires user design approval before implementation. No mockup is
included in this phase.

| Decision needing approval | Minimum mockup |
| --- | --- |
| Vocabulary settings information architecture, list density, terminology, and whether “Vocabulary” and “Replacements” are one section or separate tabs. | One Settings window state with empty, populated/search, and add/edit sheet states. |
| Rule-editor labels and preview treatment, including how an exact match is explained without suggesting acoustic learning. | Editor with written value, several heard-as aliases, preview input/result, validation error, and conflict state. |
| Display/recovery of raw ASR text beside corrected text, including whether it is inline, disclosure, copy action, or post-dictation HUD affordance. | HUD/final-result state showing corrected output, raw fallback, and keyboard focus order. |
| Import merge/replace flow, destructive confirmation, conflict resolution, and sensitive-data warning. | Import summary with valid, invalid, conflict, Merge, Replace all, cancel, and confirmation states. |
| Language truth presentation: current “Auto” badge wording, an unsupported-language state, and a future selection affordance. | Current HUD/Settings language state plus an unsupported/experimental explanatory state. |
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
3. Add counts-only diagnostics plus forbidden-content inspection tests.
4. Add benchmark result types and vocabulary/long-dictation fixtures.

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
| U-19 | Known migration and unknown future schema | Known schema atomically migrates; future schema is read-only/no overwrite. |
| U-20 | Interrupted write/corrupt primary | Last-known-good recovery is offered; dictation receives empty snapshot/raw fallback. |
| U-21 | Metrics token edits | Divergence and revokes/sec calculations match annotated sequences. |
| U-22 | No semantic-command interpretation | “replace foo with bar” remains raw/corrected only by an explicit matching rule. |

### Integration and model tests

| ID | Case | Expected assertion |
| --- | --- | --- |
| I-01 | Efficient final with an enabled alias | Correction runs after Parakeet final and before insertion/HUD output. |
| I-02 | Live Preview sequence then Parakeet final | Each draft and final use one frozen snapshot; final retains final-model authority. |
| I-03 | Empty/failing correction snapshot | Raw transcript remains visible/insertable; pipeline does not fail dictation. |
| I-04 | Rule edit/import while recording | Current session remains unchanged; next session uses new revision. |
| I-05 | Existing English public corpus without rules | Raw and rendered WER are identical and existing acceptance remains green. |
| I-06 | Versioned vocabulary corpus | Target-term and false-replacement metrics emit expected aggregate values. |
| I-07 | 30/45/60/90/120-second live fixtures | Ordered updates, bounded memory, divergence/revokes calculation, no dropped final. |
| I-08 | Candidate non-English fixture before promotion | Report only; no supported-language claim or selection behavior changes. |
| I-09 | Future selected-language adapter contract | Fails closed unless both draft/final support and fixture validation are declared. |
| I-10 | Model-native bias adapter unavailable | Post-ASR rules still work; UI/API does not claim model biasing. |

### UI and accessibility tests (after approval)

| ID | Case | Expected assertion |
| --- | --- | --- |
| UI-01 | Empty settings state | Explains explicit local rules; no suggestion of automatic learning. |
| UI-02 | Add/edit/disable/delete/search | Native controls update visible state and persist across relaunch. |
| UI-03 | Rule preview and conflict | Preview is deterministic; save is blocked with an accessible conflict message. |
| UI-04 | Keyboard-only traversal | All list/editor/preview/import controls reachable, ordered, and operable. |
| UI-05 | VoiceOver | Labels distinguish written output from heard-as aliases; errors announced once. |
| UI-06 | Corrected final and raw fallback | User can identify/copy the intended text without ambiguity. |
| UI-07 | Import preview/cancel/merge/replace | Counts and destructive confirmation match the approved mockup; cancel changes nothing. |
| UI-08 | Dynamic Type, contrast, reduced motion | No clipped values or color-only validation; no new distracting animation. |
| UI-09 | Language truth | No unsupported language appears selectable or detected; wording matches approved mockup. |

### Performance, reliability, and security tests

| ID | Case | Expected assertion |
| --- | --- | --- |
| P-01 | 5,000 entries/20,000 aliases, ordinary utterance | Correction p95 <= 100 ms; no main-thread work. |
| P-02 | Long live dictation under maximum rule set | Existing update/stop-to-final/memory gates remain satisfied. |
| P-03 | 20 consecutive sessions | No retained snapshots, file handles, subscriptions, or unbounded memory growth. |
| S-01 | Diagnostic event capture at every level | No raw/corrected text, vocabulary value, rule ID, filename, clipboard, app text, or audio appears. |
| S-02 | Allowlist mutation attempt | Unknown diagnostic field is discarded; new aggregate fields require explicit tests. |
| S-03 | Import adversarial corpus | Size/depth/count limits, invalid Unicode, duplicate keys, symlink/path cases, and failed atomic writes are safe. |
| S-04 | Export destination and content inspection | Only documented vocabulary document is written after explicit action. |
| S-05 | Network monitor during all vocabulary flows | Zero network requests. |
| S-06 | Permission boundary | Vocabulary management never requests microphone, Accessibility, screen, clipboard, or network permission. |

## 10. Requirements-to-tests traceability

| Requirement | Primary tests | Acceptance evidence |
| --- | --- | --- |
| Honest English-only language truth | I-08, I-09, UI-09 | Per-language corpus manifest and accepted result before promotion. |
| Explicit proper-noun vocabulary | U-02–U-10, I-06, UI-01–UI-03 | Vocabulary target-term report. |
| Deterministic replacements | U-03–U-12, U-16 | Golden fixtures and randomized-order property test. |
| No silent learning or semantic commands | U-22, UI-01, UI-09, S-05 | Source review and network/permission test. |
| Snapshot consistency | U-15, I-02, I-04 | Live sequence fixture. |
| Raw fallback and final authority | I-01–I-03, UI-06 | Efficient and Live Preview integration run. |
| Import/export and safe migration | U-17–U-20, UI-07, S-03–S-04 | Recovery and transaction test report. |
| Correction quality | U-21, I-05–I-07, P-01–P-03 | Versioned model/corpus report with raw and rendered metrics. |
| Privacy/security | S-01–S-06 | Diagnostics scan, network monitor, and adversarial import run. |
| Accessible approved UI | UI-04–UI-09 | XCUITest plus manual VoiceOver verification against mockup. |

## 11. Open questions and risks

1. **Language evidence:** Verify the pinned model cards/API behavior under the
   exact revisions before any language capability registry is introduced. The
   current source alone proves neither a supported-language list nor language
   identification quality.
2. **Normalization library:** Select and pin a Swift Unicode/token-boundary
   implementation that has stable cross-macOS behavior. Add golden tests before
   treating NFKC/case-folding behavior as a compatibility promise.
3. **Raw-text retention UX:** Decide where raw ASR is exposed and for how long;
   do not quietly create transcript history while implementing the fallback.
4. **Import interoperability:** Decide whether the v1 JSON schema is public and
   stable at launch or marked preview. The answer controls compatibility and
   unknown-field preservation policy.
5. **Ambiguous natural speech:** Exact aliases cannot reliably resolve all
   proper nouns. Avoid marketing them as pronunciation training until a
   model-native bias capability passes the separate evidence gate.
6. **UI approval:** The six mockup categories in section 7 need user approval
   before any Settings/HUD/import surface is implemented.
7. **Correction-versus-insertion interaction:** The live-insertion feature must
   consume only the rendered text it owns, retain its ownership safety contract,
   and never treat a correction as permission to overwrite user text.
