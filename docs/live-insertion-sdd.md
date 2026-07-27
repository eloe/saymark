# Live insertion — evidence-gated software design and test specification

**Status:** policy-core design approved for implementation; no cross-application live field mutation is approved.
**Scope:** establish safe, testable policy for writing stable dictation text only after platform and UX evidence proves Saymark can distinguish its own provisional tail from user-owned text. The current atomic final paste is the shipped delivery contract.

Independent review record: [Claude Opus 5 review](reviews/live-insertion-claude-opus-5-2026-07-26.md). It permits Slice 1 only. Slices 2–5 are blocked by B-01 through B-05 and the evidence table below.

## Product contract and requirements

Live insertion is an opt-in future delivery policy for Live Preview. Efficient mode and HUD-only must remain non-live; unknown, terminal, and protected targets retain atomic final delivery. A future live session may write a stable prefix at the captured insertion point and revise only Saymark's provisional tail. It fails closed before a further write whenever ownership is uncertain.

| ID | Requirement | Acceptance criterion |
| --- | --- | --- |
| LI-01 | Capture a lease before any live write. | Accessibility is trusted; focus, editable role, collapsed selection, capability, and protection state satisfy the certified tier. |
| LI-02 | Preserve prefix/tail ownership. | Released prefix is never selected or rewritten. A bounded read-only ranged read validates Saymark's tail before any selection or replacement. |
| LI-03 | Meet human-visible latency and stability gates. | Pass the authoritative [performance acceptance](performance-acceptance.md#human-perceived-live-insertion-gates), including its live-insertion step/freeze reconciliation and committed-stability bounds. |
| LI-04 | Fail closed on loss of ownership. | Focus/PID/element/range change, same-offset content substitution, user edit, undo/redo, target close/termination, invalid AX element, secure transition, notification/order error, or timeout produces zero later writes. |
| LI-05 | Distinguish final delivery states. | In fallback-final, where no live tail was written, existing atomic final insertion occurs exactly once. In frozen-final, where a live tail exists but is unverified, there are zero AX writes and zero synthetic paste events; recovery is copy-only until an explicit user-approved action. |
| LI-06 | Preserve security and privacy. | No synthetic event or AX mutation in protected states; no provisional clipboard write; diagnostics and remote events use closed enums/buckets only. |
| LI-07 | Retain compatibility and mode isolation. | Atomic paste is the current shipped contract, not proven real-app compatibility evidence. Efficient, HUD-only, Tier C, and Tier D emit zero AX writes and zero synthetic events. |
| LI-08 | Be ordered, bounded, and cancelable. | No stale/concurrent write after stop/restart/focus loss/quit; AX I/O is off-main, bounded, and timeout fails closed. |

## Non-negotiable evidence gates

No production code may mutate another application field until every B gate is closed with a committed evidence artifact and a follow-up independent review. The absence of B-01 alone disqualifies Tier A.

| Gate | Required evidence artifact | Status |
| --- | --- | --- |
| B-01 public acknowledged AX mutation | Reference NSTextView spike: read-tail-range without selection, then select-tail/replace-tail; measure notification ordering/coalescing, self-vs-user origin ambiguity, and transport versus acknowledgement. If ambiguity remains, Tier A is not shippable. | Missing — blocks Tier A API/UI. |
| B-02 same-offset substitution | Privacy-reviewed ranged-read spike and adversarial proof that same-length replacement at the same range is detected before selection or the next write. | Missing — blocks ownership claim. |
| B-03 frozen-final delivery | Test evidence proving frozen-final emits zero AX writes and zero synthetic paste, with copy-only recovery. | Missing — blocks live settlement. |
| B-04 protected AX behavior | Secure-input × AX-write matrix for secure roles and IsSecureEventInputEnabled; determine whether the one pre-activation in-flight operation can land after protection. Result must establish rejection or force Tier D. | Missing — blocks AX mutation. |
| B-05 AX execution/liveness | Dedicated-run-loop observer and messaging-timeout experiment against deliberately hung target; timeout must fail closed within the mutation budget. | Missing — blocks coordinator. |

Evidence is versioned by macOS, target/control, architecture, fixture, and test harness. Target name/version may appear in the evidence artifact, never in runtime diagnostics or authority decisions.

## Ownership model

### Data boundary and proof

A lease holds ephemeral process/AX element identity, role/capabilities, numeric ranges, mutation generation, and **Saymark-authored tokens**. Saymark may retain its own prefix and tail in memory only for the active session so it can compute final delta. It never persists or logs them.

Before every future replacement, Saymark uses the public read-only ranged AX query kAXStringForRangeParameterizedAttribute for the tracked tail range; it must not first select that range. Its availability is a Tier A capability requirement. The read is capped at **64 UTF-16 code units**. This is a narrow, privacy-reviewed exception: a lost lease can cause the result to contain user text. The value is compared in memory to Saymark's own tail, immediately discarded unhashed, never logged/persisted/transmitted, and any mismatch freezes the lease without changing selection. Only after a matching ranged read and current cursor/range revalidation may a future mutator select the known-owned tail; any unprovable read/select ordering race disqualifies the target. A tail that would exceed the cap enters the explicit tail-throttled state. This read-back is necessary to detect same-length, same-offset substitution; range equality or notification absence is not ownership proof.

Committed prefix is irrevocably released and is never selected or changed. Revisable tail is the only contiguous selectable/replacement range. The conceptual field is user-before + committed-prefix + tail + user-after; user-before/user-after are never read, retained, or logged.

### State and exact-once rule

~~~text
idle → capture-target → live(lease) → settle-owned-tail → idle
                         │     │           │
                         │     ├ tail >64 → tail-throttled (HUD carries excess; no further live field writes)
                         │     │                   ├ verified ownership → settle-owned-tail → idle
                         │     │                   └ ownership loss → frozen-final → copy-only / explicit approved recovery → idle
                         ├ unsupported before a tail write ─→ fallback-final → existing atomic final once → idle
                         └ ownership loss ───────→ frozen-final → copy-only / explicit approved recovery → idle
~~~

tail-throttled is a live-lease substate: the existing capped tail remains untouched, later provisional content is HUD-only, and no further live field write is attempted. On stop, it routes to settle-owned-tail only when ownership is re-proven; otherwise it routes to frozen-final. It never routes directly to fallback-final because a tail was already written. fallback-final is reachable only before a live tail is written. A secure-input transition with no tail written routes here; the existing atomic path itself refuses secure paste and leaves the final result for copy/HUD recovery. Where automatic insertion is available, fallback-final uses the current settled field string: final transcript plus one ASCII trailing space. frozen-final is reachable after any tail write whose ownership cannot be re-proven. It leaves residual field text untouched, performs no automatic final insertion, and offers only copy until the user explicitly chooses an approved recovery. It never delivers full final text blindly at the current cursor.

### Stability policy

The first field appearance gate measures **provisional** text. Initial policy is two matching ordered hypotheses (N=2) and minimum tail age T=160 ms before a token can become committed; both are experiment-revisable only with renewed performance evidence. A committed token is never revoked. For eligible targets, maximum provisional revision depth is four words and p95 provisional revoked-word rate is at most two words per second. LI-P06 enforces these limits together with the authoritative performance gates.

### AX and user-edit invalidation

Future AX work uses a dedicated thread with a CFRunLoop hosting AXObserver. Observer callbacks hop to the serial coordinator; they do not mutate UI. All AX reads/writes are off the main actor and set AXUIElementSetMessagingTimeout to **100 ms**. A timeout, unavailable run-loop source, transport error, missing/late expected observation, or operation exceeding the 150 ms mutation hard limit freezes the lease. LI-S07 asserts both the timeout behavior and that every AX call runs off-main.

Secure-input state is polled every **25 ms** only while a live lease exists, then stopped synchronously when that lease settles, freezes, or is released. It is included in the existing idle-CPU lifecycle budget and must not regress it. A pre-I/O check and the one-operation-in-flight rule prevent new dispatches after detection. They cannot recall a dispatch already in flight when secure input activates: **at most one** pre-activation AX/synthetic mutation may complete afterward. The poll interval describes detection latency, not a security guarantee and not the 150 ms performance SLO. B-04 must empirically determine whether that one residual operation can land in a protected field; until then all AX mutation remains blocked.

The coordinator must invalidate on focus/application/PID/element/range change; read-back mismatch; pointer/keyboard selection; user edit; undo/redo; IME, spellcheck, or autocorrect change; target termination, document/window close, kAXErrorInvalidUIElement; secure state; observer failure; stop/restart/quit; or stale sequence/generation. It never restores focus, cursor, or selection.

B-01 must first demonstrate a public mutation primitive with an origin/ordering acknowledgement. Until then, this is a required spike design, not a Tier A implementation commitment.

## Compatibility, protection, and UX constraints

| Tier | Current policy |
| --- | --- |
| A — verified AX replacement | Blocked pending B-01…B-05 and all UX approvals. A reference native control must satisfy every evidence/test gate. |
| B — verified synthetic + AX observation | Blocked pending Tier A evidence plus per-control real-app certification. Tier B live synthesis is **disabled in hold mode** unless D-07 approval and LI-I24 prove zero modifier contamination. |
| C — atomic final | Terminal/PTY, editors, rich text/IME, remote desktop, unknown/custom controls, and uncertified web/Electron. HUD updates; current atomic final path only. |
| D — protected/unavailable | Missing Accessibility, no focus, read-only/password/secure role, secure input, or AX failure. No AX mutation, no synthetic event, no provisional clipboard write. Final copy/HUD recovery only. |

Secure role includes AXSecureTextField/AXTextFieldSecure and any certified equivalent. IsSecureEventInputEnabled is not an AX-write permission grant: no AX write is allowed until B-04 empirically proves behavior. Existing final atomic paste retains its snapshot/change-count/delayed restore policy, but must skip restore when its snapshot carries org.nspasteboard.ConcealedType or org.nspasteboard.TransientType so Saymark never republishes such content.

Toggle HUD Stop must be demonstrably non-focus-stealing. If it cannot preserve the lease, it enters frozen-final, never a blind settle. This is tested through LI-I23. Native undo must be one session-level undo step; otherwise live insertion remains disabled for that target.

Diagnostics and PostHog are separate potential sinks. Existing remote analytics stays dormant/disabled under its existing gate. Any future live-insertion event in either sink uses a typed closed enum plus bucketed integer values; it cannot use target identity, free-form reason/state/source/outcome, exact text length, or bundle_id. No live-insertion call site may provide bundle_id.

## Test and evidence contract

Fakes must model AX ranges, read-only ranged-tail read-back, notifications, focus, secure poll, timeout, mutation dispatch, and clocks. Real-target certification uses a named real-application harness, not the current in-process daily-driver fakes.

| IDs | Level | Required cases |
| --- | --- | --- |
| LI-U01…U05 | Unit | Token/diff/Unicode/punctuation and prefix/tail invariants. |
| LI-U06…U09 | Unit | N=2/T=160 stability, acknowledgement-gated commit, tail retraction, and final delta. |
| LI-U10…U16 | Unit | Focus/range/edit/notification/AX/stale-generation loss causes zero later writes. |
| LI-U17…U21 | Unit | Capability classifier rejects read-only, noncollapsed, untrusted, unknown, terminal; accepts only fully evidenced tier capabilities. |
| LI-U22…U25 | Unit | Ordered coalescing, one operation in flight, cancellation, idempotent cleanup. |
| LI-U26…U29 | Unit | Secure start/mid-session means no synthetic event **and no AX mutation**; no provisional clipboard; newer-copy preservation; concealed/transient snapshot is not restored. |
| LI-U30…U34 | Unit/property | Exact-once state accounting and randomized event schedules never rewrite released prefix or write after invalidation. |
| LI-U35 | Unit | Same-length content substitution at identical offsets is detected by bounded read-only ranged-tail read-back. |
| LI-U36 | Unit | frozen-final emits zero AX mutations and zero synthetic paste events. |
| LI-U37 | Unit | AX write refused for secure role and IsSecureEventInputEnabled. |
| LI-U38 | Unit | 25 ms secure poll detects activation within the 125 ms bound. |
| LI-U39 | Unit | Logger/remote event values are rejected unless closed enum or bucket; no bundle_id at live call sites. |
| LI-U40 | Unit | User undo and redo during a session invalidate the lease. |
| LI-U41 | Unit | Target termination, closed document/window, and invalid AXUIElement fail closed. |
| LI-U42 | Unit | Efficient, HUD-only, Tier C, and Tier D issue zero AX mutations and zero synthetic events. |
| LI-U43 | Unit | Ownership verification reads kAXStringForRangeParameterizedAttribute without mutating selection; unavailable ranged read rejects Tier A. |
| LI-U44 | Build/unit gate | LiveInsertionPolicy imports neither ApplicationServices nor CoreGraphics and references no AX write, CGEvent, or CGEvent post API. |
| LI-I01…I08 | Integration | Reference Tier A, correction/punctuation/long utterance, focus/cursor/user-edit loss. Blocked until B gates. |
| LI-I09…I11 | Real-app integration | Real Safari, Chrome, and a production Electron app via LiveInsertionRealTargetHarness: ten repetitions/version, exact final, ordered proof. Blocked until B gates. |
| LI-I12 | Real-app integration | Real Terminal/PTY and code editor: zero live operations; existing atomic final exactly once over ten repetitions. |
| LI-I13…I15 | Integration | Missing AX, secure/password/protected state, clipboard race: no protected AX/synthetic operation and recovery preserved. |
| LI-I16…I21 | UI | Hold/toggle/restart/quit, VoiceOver, keyboard-only, Reduce Motion, localized recovery. |
| LI-I22 | Integration | For a safe settled lease, live settled field string is byte-identical to atomic final transcript plus trailing space. |
| LI-I23 | Integration | Toggle-mode Stop HUD click is non-focus-stealing or freezes per approved recovery; never blind-settles. |
| LI-I24 | Integration | Hold-mode Tier B: zero modifier-contaminated synthetic events throughout a held chord. |
| LI-I25 | Integration | Concealed/transient pasteboard snapshot is not republished by delayed restore. |
| LI-P01…P05 | Performance | Authoritative latency/resource gates, no queue growth, 20 warmed runs/target. |
| LI-P06 | Performance | N/T policy, max four-word revision depth, p95 revoked provisional words/s <= 2. |
| LI-R01…R03 | Reliability | 10,000 AX/hypothesis schedules: no crash/deadlock/leak/post-cancel write. |
| LI-S01…S06 | Security | Reordered AX, check/write race, secure/clipboard race, diagnostics scan, static privacy review. |
| LI-S07 | Security | Deliberately hung target with 100 ms messaging timeout fails closed with no mutation; asserts all AX I/O runs off-main. |

Before Tier A is unblocked, commit: B-01 spike result, B-02 adversarial read-back result, B-04 secure matrix, B-05 hung-target result, and real application evidence for its target. The current compatibility matrix consists of in-process fakes and is insufficient evidence for Safari, Chrome, Electron, or Terminal.

## Implementation slices

1. **Policy core, no writes — permitted only behind a mechanical boundary:** create a separate LiveInsertionPolicy target for tokenizer/stability, lease/classifier/generation, throttle state, and typed telemetry schema. Its sources may not import ApplicationServices or CoreGraphics and may not reference AXUIElementSetAttributeValue, CGEvent, or any CGEvent post API. Before policy code lands, add a CI boundary test/gate that scans this target and fails on those imports or symbols; LI-U44 verifies that gate. This target owns no AX adapter and has no production mutation path.
2. **Evidence spikes — not implementation:** produce B-01/B-02/B-04/B-05 artifacts. Failure retains Tier C/D; it does not weaken the safety contract.
3. **Tier A coordinator — blocked:** only after all B evidence, security review, and D-01…D-06 approval.
4. **Product integration — blocked:** only after Tier A is certified; opt-in first.
5. **Tier B certification/promotion — blocked:** only after Tier A, real-app results, D-07 if hold mode is requested, user testing, and final review.

## Approved UI/design contract

The recommended native macOS package was approved on 2026-07-26. This approval
resolves D-01…D-07 but does not waive B-01…B-05 or authorize Slices 2–5 before
their evidence gates pass.

| Decision | Approved behavior |
| --- | --- |
| D-01 setting/default | Keep atomic final-on-release as the safe default. “Insert while I speak” is an explicit opt-in, and its consent says provisional words are written into the active app and may change before settling. Unsupported fields automatically use final-on-release. |
| D-02 revisable-text cue | The HUD labels the state “Live here” and uses a native dotted underline for provisional words with the accessible description “Underlined words may still change.” Reduce Motion removes nonessential transition animation. |
| D-03 ownership-loss recovery | Show “Editing paused,” explain that live updates stopped because the text changed outside Saymark, and offer **Copy final text** plus **Done**. Never perform an implicit replacement. HUD-click Stop follows the same ownership rule. |
| D-04 undo | Offer a single coalesced Undo/Redo only where target-specific evidence proves it is safe. Otherwise make no special undo claim and preserve the target application’s native history. |
| D-05 compatibility disclosure | Show “Live here” only for a certified target; otherwise show/use “Final on release,” including Terminal and every unverified control. |
| D-06 residual provisional text | Leave residual provisional text as-is after ownership loss and offer Copy final text. Never silently replace or remove unverified text. |
| D-07 Tier B hold mode | Held-chord live synthesis remains disabled until modifier-discipline evidence proves it cannot emit contaminated events. |

## Traceability

| Requirement | Tests | Evidence/approval |
| --- | --- | --- |
| LI-01 | LI-U17…21, LI-I01, LI-I13 | B-01/B-05, capability record |
| LI-02 | LI-U01…09, LI-U34…35, LI-U43, LI-I01…04 | B-02 and privacy review |
| LI-03 | LI-P01…06 | Authoritative performance report |
| LI-04 | LI-U10…16, LI-U35, LI-U40…41, LI-S01…07 | B-01/B-02/B-05 |
| LI-05 | LI-U06…09, LI-U30…36, LI-I01…15, LI-I22…23 | B-03, D-03, D-06 |
| LI-06 | LI-U26…29, LI-U37…39, LI-I13…15, LI-I25, LI-S03…06 | B-04, telemetry review |
| LI-07 | LI-U17…21, LI-U42, LI-I09…12 | Real-app certification |
| LI-08 | LI-U22…25, LI-U38, LI-U40…41, LI-U44, LI-R01…03, LI-S07 | B-05 and policy boundary gate |
