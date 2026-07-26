# Live insertion — software design and test specification

**Status:** implementation design; not shipped.  
**Scope:** write stable dictation text into the active field while the user is speaking, without ever revising text Saymark cannot prove it owns. The current single final paste remains the compatibility baseline and fallback.

This implements the planned follow-up in [product roadmap](product-roadmap.md#planned-follow-up--live-field-insertion) and its [performance contract](performance-acceptance.md#human-perceived-live-insertion-gates). It does not change model selection, audio retention, vocabulary, or history.

## Product contract

In-field delivery gains an opt-in **Live insertion** policy for Live Preview. While speaking, Saymark writes a stable prefix at the captured insertion point and may revise only its provisional tail. On stop it replaces the remaining tail with the authoritative final transcript, then releases ownership. If ownership cannot be proven, live revision ends before another field mutation. Efficient mode continues using atomic final insertion; HUD-only never mutates another application.

### Requirements

| ID | Requirement | Acceptance criterion |
| --- | --- | --- |
| LI-01 | Capture one active target and insertion point before recording. | No live mutation begins without Accessibility trust, writable supported target, collapsed cursor, and valid ownership lease. |
| LI-02 | Maintain committed-prefix/revisable-tail ownership. | Corrections change only the current Saymark tail; released prefix is never selected, deleted, or rewritten. |
| LI-03 | Meet the human-visible latency contract. | The performance gates below pass on every supported target. |
| LI-04 | Fail closed on ownership loss. | Focus, target, selection/cursor, user edit, notification, or sequence mismatch stops revision before a further mutation. |
| LI-05 | Settle exactly once. | Final text replaces the owned tail once, or one atomic fallback delivers the unresolved final text; no duplicated prefix/tail. |
| LI-06 | Preserve security and privacy. | Secure input is never bypassed; diagnostics contain no text, clipboard, target identity, or field content. |
| LI-07 | Retain compatibility. | Unsupported/unproven targets use the existing atomic final insertion path. |
| LI-08 | Be ordered and cancelable. | No stale or concurrent mutation can run after stop, restart, focus loss, or app termination. |

## Ownership design

### Definitions and invariants

* **Lease:** one dictation-scoped capability bound to the frontmost process PID, AXUIElement identity, target capability tier, and initial collapsed selected range. It contains no field text.
* **Committed prefix:** Saymark-inserted text released irrevocably; it is never selected or changed by this session.
* **Revisable tail:** the only contiguous range Saymark may replace. Store its UTF-16 length, expected selected range, mutation sequence, and operation token—not field contents.
* **Ownership proof:** same target is focused; selected range exactly matches the expected tail end; lease and operation generation are current; no unmatched AX notification exists.
* **Fail closed:** an indeterminate AX read, missing/late notification, timeout, unsupported attribute, synthetic-input failure, or ordering conflict loses ownership. It never retries into the field.

The conceptual field is user-before + committed-prefix + tail + user-after. Saymark can affect only tail; it must never read, retain, or log user-before/user-after.

### State machine

~~~text
idle
  └─ hotkey → captureTarget → live(lease) ─ update → live(lease)
                                  │  │                       │
                                  │  ├ ownership lost ───────┤
                                  │  └ secure/unsupported ───┤
                                  ▼                          ▼
                           fallback-final              frozen-final
                                  └─ stop → atomic final / HUD / clipboard → idle

live(lease) ─ stop → settle-owned-tail → idle
~~~

fallback-final has written no live tail and retains the current final atomic insertion. frozen-final leaves its existing tail unchanged. On stop it must not guess where to apply the model final text; it exposes the approved recovery action (D-03).

### Publication and settlement

1. On hotkey down, show listening feedback first. Capture the focused target only if Accessibility is trusted, secure input is off, selection is collapsed, the role is editable, and the target is live-capable. Otherwise choose fallback-final without moving focus or synthesizing input.
2. Normalize each ordered ASR hypothesis into word tokens. Find the longest common prefix with the previous hypothesis. Commit a word only after it survives N consecutive hypotheses and a minimum age T; N/T are versioned, experiment-backed policy values. Punctuation and whitespace belong to the preceding token so the tail stays contiguous.
3. Coalesce newer hypotheses while one target operation is in flight. A serial coordinator revalidates the lease, selects exactly the current tail, replaces it with newly committed delta plus candidate tail, awaits acknowledgement, then advances range/generation. Never keep more than one obsolete pending mutation.
4. Words cross into prefix only after that operation is acknowledged. Failed acknowledgement freezes ownership rather than assuming text was written.
5. On stop, cancel pending publication, await the last acknowledged operation, revalidate, then replace the tail with final delta once. If finalization/revalidation fails, touch nothing and use recovery policy. Tear down observer, tasks, ranges, and tokens.

The mutator must have an acknowledgement mechanism. For AX-capable native controls it must replace only a selected range; for synthetic replacement it must demonstrate ordered AX selection/value acknowledgement. Blind Command-V is not live capable.

### AX target, range, focus, and user-edit loss

Capture system-wide focused application and AXFocusedUIElement on the main actor. A narrow adapter reads only focused element, selected text range, role, editability, and selected-range support. It registers an AXObserver for application/focus changes and selected-range/value changes before the first mutation.

Immediately before and after every operation require: same frontmost process and focused element; expected collapsed cursor before selecting; expected cursor/range after acknowledgement; no unmatched target-change notification; and current session generation. Do not read AXValue to prove ownership, and never restore user focus, selection, or cursor.

Keyboard navigation, pointer selection, target activation change, uncorrelated text/value notification, IME composition, spellcheck/autocorrect change, accessibility-server error, or observer failure invalidates the lease. A control that cannot reliably report those facts is not live capable.

### Compatibility tiers

| Tier | Targets | Live behavior | Stop/failure behavior |
| --- | --- | --- | --- |
| A — verified AX replacement | Native AppKit/Cocoa editable controls with stable focused-element, range, mutation acknowledgement, and notification ordering. | Prefix/tail revision allowed. | Settle tail or freeze/recover. |
| B — verified event + AX observation | Browser textarea/contenteditable and Electron controls that pass a per-version suite with synthetic replacement plus acknowledgement. | Allowed only by capability certification, never name-based allowlist. | Same as A; any regression demotes to C. |
| C — atomic final | Terminal/PTY, code editor, custom canvas, remote desktop, rich text/IME, unsupported browser/Electron, and unknown targets. | No live field mutation; HUD stays live. | Existing one-shot atomic paste/copy/HUD. |
| D — protected/unavailable | Secure Event Input, missing Accessibility, no focus, read-only/password field, or AX failure. | No synthetic input or provisional clipboard write. | Existing final copy/HUD recovery. |

Capability is evaluated per lease. Bundle ID, target name, historical success, or apparent cursor never grants authority. Terminal is intentionally C even if it exposes a cursor-like range because atomic paste is the proven contract.

### Secure input, clipboard, undo

If secure input is active at start or turns on mid-session, invalidate the lease and send no more events. Never put provisional text on the general pasteboard. At final recovery, retain current behavior: final transcript may remain on the pasteboard for manual use, and secure input is never bypassed. Existing atomic final paste keeps its snapshot/change-count/delayed-restore guard and must preserve a newer user copy.

Live mutation should use a private replacement mechanism, not the general pasteboard. A mutator requiring pasteboard use remains Tier C pending an approved privacy/clipboard design and proof of no clipboard loss. Recommended undo is one native target undo step per settled Saymark session, not each update; without verified coalescing, live insertion stays disabled for that target.

### Concurrency and telemetry

DictationSession continues publishing on the capture queue. A LiveInsertionCoordinator owns lease, hypothesis sequence, pending work, generation, and AX observer on one serial actor/queue. UI remains MainActor; final ASR remains detached. It accepts monotonic sequence numbers, discards stale updates, executes one mutation at a time, and revalidates immediately before dispatch.

Stop, restart, quit, focus loss, and observer failure synchronously bump generation before continuations may mutate. Cleanup is idempotent; no capture callback directly touches AX or UI.

Diagnostics may contain randomized session ID, target tier/capability flags, bucketed numeric range/tail lengths, counts, outcome/reason category, latency, lag, and revision depth. They must not contain text/tokens, field/selected text, clipboard, window title, URL, app/bundle name, PID, AX description, or stable target fingerprint. Remote analytics remains disabled.

## Performance gates

All Tier A/B release runs use warmed Release builds and consented/versioned fixtures. They supplement the existing model, WER, memory, and lifecycle gates.

| Metric | p50 | p95 | Hard limit |
| --- | ---: | ---: | ---: |
| Hotkey down → first visible listening feedback | <= 50 ms | <= 100 ms | 200 ms |
| Reference-word end → first field appearance | <= 250 ms | <= 400 ms | 500 ms |
| Hypothesis publication → completed field mutation | <= 50 ms | <= 100 ms | 150 ms |
| Stop gesture → final settled text | <= 300 ms | <= 500 ms | 750 ms |
| Continuous-speech visible freeze | — | — | <= 300 ms |

Feed cadence remains 100–160 ms, currently 160 ms. Mutations must remain ordered with no insertion/inference backlog. A cadence change repeats the documented experiment. Measurements record content-free timing anchors, hypothesis sequence, mutation completion, and fixture word timestamps only.

## Test pyramid and required cases

Fakes model AX reads/notifications, target focus, mutation completion, clock, and input dispatch deterministically. Real-target tests cover the OS boundary.

| IDs | Level | Requirement(s) | Required cases/assertions |
| --- | --- | --- | --- |
| LI-U01…U05 | Unit | LI-02 | Token diff; whitespace/punctuation; Unicode/emoji UTF-16 ranges; empty/short hypothesis; LCP changes never make committed text revisable. |
| LI-U06…U09 | Unit | LI-02, LI-05 | Horizon commits only acknowledged words; retractions change tail only; final replaces tail exactly once; empty final uses recovery policy. |
| LI-U10…U16 | Unit | LI-04, LI-08 | PID/element mismatch, cursor/selection move, user edit notification, missing/late ack, AX error, stale generation cause zero further operations. |
| LI-U17…U21 | Unit | LI-01, LI-07 | Reject read-only, noncollapsed, unsupported role, untrusted/unknown/terminal; accept only complete A/B capabilities. |
| LI-U22…U25 | Unit | LI-08 | Ordered coalescing; one operation in flight; stop/restart races cannot dispatch stale work; cleanup is idempotent. |
| LI-U26…U29 | Unit | LI-06 | Secure input start/mid-session; no provisional clipboard write; atomic newer-copy preservation; telemetry schema rejects sensitive keys and values. |
| LI-U30…U34 | Unit/property | LI-02, LI-04, LI-05 | Exact-once across no speech/focus loss/synthetic failure/finalization failure; randomized hypothesis/user-event interleavings never touch released prefix or mutate after invalidation. |
| LI-I01…I04 | Integration | LI-02, LI-05 | Tier A native field: stable speech, correction, punctuation, and 30–120 s. Exact final once; committed words unchanged; tail ordered; undo follows approval. |
| LI-I05…I08 | Integration | LI-04 | Switch app, move cursor/select, pointer edit, and target notification. Stop before overwrite; leave text/focus/selection untouched; show approved recovery. |
| LI-I09…I11 | Integration | LI-07 | Browser textarea/contenteditable and Electron control: ten repetitions/version; exact final, no duplicate prefix, ordered acknowledgement. Failure demotes to C. |
| LI-I12 | Integration | LI-07 | Terminal/PTY and code editor: zero live operations, HUD updates, existing atomic final exactly once over ten runs. |
| LI-I13…I15 | Integration | LI-06 | Missing AX, secure input/password field, clipboard race: no protected synthetic event/provisional clipboard; final recovery and newer-copy policy preserved. |
| LI-I16…I21 | UI | LI-08, LI-06 | Hold/toggle, rapid stop/start, quit, VoiceOver, keyboard-only, Reduce Motion, localizable recovery. No stale write or retained observers/tasks. |
| LI-P01…P05 | Performance | LI-03, LI-08 | Twenty runs/target meet all gates; 30/60/90/120 s at 160 ms have no queue growth and meet existing CPU/memory/RTF. Report p50/p95/max/freeze/backlog/revision depth/fixture-hardware metadata. |
| LI-R01…R03 | Reliability | LI-08 | Fuzz 10,000 hypothesis/AX schedules: no crash, deadlock, leak, or post-cancel operation; no per-session retained resource after stop. |
| LI-S01…S06 | Security | LI-04, LI-06 | Delayed/reordered/lying AX; check/write race; secure-input and clipboard races; diagnostics sensitive-data scan; static review finds no AXValue read, keylogging, identity authority, or bypass. |

Manual release validation additionally uses an unlocked interactive session, since macOS limits UI/HID automation while locked.

## Implementation slices

1. **Policy core, no writes:** pure tokenizer/stability, lease state, classifier, generations, telemetry schema, and LI-U tests. Gate: property/fuzz tests pass; production behavior unchanged.
2. **Tier A coordinator:** AX adapter/observer and reference native control behind disabled feature flag. Gate: LI-I01…I08, LI-P01, LI-S01…S06 pass; recovery/undo UX approved.
3. **Product integration:** DictationController, HUD, setting, accessibility copy, opt-in. Gate: hotkey/UI/accessibility/performance/fallback tests pass.
4. **Tier B certification:** certify browser/Electron one control at a time. Gate: ten exact-once runs and performance gates; failures remain C.
5. **Promotion:** default only after user testing, security review, and evidence. C/D retain atomic behavior indefinitely.

## UI/design approvals needed

No UI is created by this specification. Approval is required before product behavior changes.

| Decision | Minimum mockup required |
| --- | --- |
| D-01 setting/default | Settings showing atomic-final versus live choices, opt-in/default, permission and privacy copy. |
| D-02 revisable-text cue | HUD + focused-field storyboard distinguishing committed/provisional text, VoiceOver and Reduce Motion states. |
| D-03 ownership-loss recovery | HUD states for live, frozen cursor move, secure/protected, and final fallback; exact actions and keyboard route. |
| D-04 undo | Field storyboard showing one Undo/Redo for normal settle and ownership-loss case. |
| D-05 compatibility disclosure | Compact status for “live here” versus “final on release,” including terminal. |

## Open questions and risks

1. **Public mutation primitive:** prototype a public macOS AX selected-range replacement with reliable acknowledgement before Tier A API/UI commitment.
2. **AX TOCTOU:** notifications are not a lock; target-specific ordering may reject all but the reference control.
3. **Final after lease loss:** choose copy-only, no automatic final change, or explicit user-confirmed replacement; never guess location.
4. **Undo coalescing:** native/browser/Electron grouping differs; do not promote without verified user-level undo.
5. **IME/rich text/autocorrect:** automatic target changes invalidate ownership; exclude initially until evidence exists.
6. **Stability N/T:** tune against word latency and correction churn; low latency with visible churn fails product testing.
7. **Privacy:** even ephemeral AX range/identity handling needs review; do not debug compatibility with target identifiers.
8. **OS/version variance:** record versions in certification evidence but do not use identity/version as runtime authority.

## Traceability

| Requirement | Primary tests | Release evidence |
| --- | --- | --- |
| LI-01 | LI-U17…21, LI-I01, LI-I13 | Capability matrix and Tier A result |
| LI-02 | LI-U01…09, LI-U34, LI-I01…04 | Correction/revision report |
| LI-03 | LI-P01…05 | Twenty-run timing report |
| LI-04 | LI-U10…16, LI-I05…08, LI-S01…05 | Adversarial AX + focus-loss result |
| LI-05 | LI-U06…09, LI-U30…34, LI-I01…15 | Per-tier ten-run result |
| LI-06 | LI-U26…29, LI-I13…15, LI-S03…06 | Security review + diagnostic scan |
| LI-07 | LI-U17…21, LI-I09…15 | Certified-tier/fallback matrix |
| LI-08 | LI-U22…25, LI-I16…21, LI-R01…03 | Fuzz/leak/UI results |

## Claude independent-review package

When Claude Opus 5 is authenticated, review this document before implementation with the current TextInjector.swift, DictationController.swift, DictationSession.swift, performance/privacy documentation, and existing TextInjector and daily-driver tests. The review is read-only.

~~~text
You are the independent SDD/TDD and security reviewer for Saymark live insertion.
Review docs/live-insertion-sdd.md and the listed current files. Do not modify files.
Identify every unsafe ownership assumption, TOCTOU or AX race, privacy/secure-input/
clipboard violation, undo or recovery ambiguity, unsupported compatibility claim,
missing test, and conflict with the atomic-final contract. Verify that requirements
and tests prevent modification of user-owned text. Classify each finding as BLOCKER,
HIGH, MEDIUM, or LOW; cite requirement/test IDs and concrete remedy. End with
APPROVE / APPROVE-WITH-CHANGES / REJECT. Treat lack of a public acknowledged AX
mutation primitive as a blocker for Tier A implementation.
~~~

