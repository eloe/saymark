# Live insertion — evidence-gated software design and test specification

**Status:** fail-closed policy core and evidence harness shipped; no production
cross-application provisional field mutation is approved or shipped. Atomic
single-shot final insertion now has its own focus/selection lease and bounded receipt,
certified for the versioned app/control rows in the
[macOS 26.5.1 real-target matrix](reviews/evidence/atomic-insertion-target-matrix-2026-08-04.md).
**Scope:** establish safe, testable policy for writing stable dictation text only after platform and UX evidence proves Saymark can distinguish its own provisional tail from user-owned text. The current single-shot final paste is the shipped delivery contract; provisional live insertion and untested app/control versions remain uncertified.

Independent review record: [Claude Opus 5 review](reviews/live-insertion-claude-opus-5-2026-07-26.md). It permits Slice 1 only. Slices 2–5 are blocked by B-01 through B-05 and the evidence table below.

## Product contract and requirements

Live insertion is an opt-in future delivery policy for Live Preview. Efficient mode and HUD-only must remain non-live; unknown, terminal, and protected targets retain single-shot final delivery. A future live session may write a stable prefix at the captured insertion point and revise only Saymark's provisional tail. It fails closed before a further write whenever ownership is uncertain.

| ID | Requirement | Acceptance criterion |
| --- | --- | --- |
| LI-01 | Capture a lease before any live write. | Accessibility is trusted; focus, editable role, collapsed selection, capability, and protection state satisfy the certified tier. |
| LI-02 | Preserve prefix/tail ownership. | Released prefix is never selected or rewritten. A bounded read-only ranged read validates Saymark's tail before any selection or replacement. |
| LI-03 | Meet human-visible latency and stability gates. | Pass the authoritative [performance acceptance](performance-acceptance.md#human-perceived-live-insertion-gates), including its live-insertion step/freeze reconciliation and committed-stability bounds. |
| LI-04 | Fail closed on loss of ownership. | Focus/PID/element/range change, same-offset content substitution, user edit, undo/redo, target close/termination, invalid AX element, secure transition, notification/order error, or timeout produces zero later writes. |
| LI-05 | Distinguish final delivery states. | In fallback-final, where no live tail was written, existing single-shot final insertion is attempted once. In frozen-final, where a live tail exists but is unverified, there are zero AX writes and zero synthetic paste events; recovery is copy-only until an explicit user-approved action. |
| LI-06 | Preserve security and privacy. | No synthetic event or AX mutation in protected states; no provisional clipboard write; diagnostics and remote events use closed enums/buckets only. |
| LI-07 | Retain compatibility and mode isolation. | Single-shot paste with bounded acknowledgement is the current shipped contract and is proven only for the app/control/version rows in the committed real-target matrix; it does not prove provisional live mutation or untested versions. Efficient and Tier C emit zero provisional/live mutations but may use that one final synthetic paste; HUD-only and Tier D emit zero external delivery events. |
| LI-08 | Be ordered, bounded, and cancelable. | No stale/concurrent write after stop/restart/focus loss/quit; AX I/O is off-main, bounded, and timeout fails closed. |

## Non-negotiable evidence gates

No production code may mutate another application field until every B gate is closed with a committed evidence artifact and a follow-up independent review. The absence of B-01 alone disqualifies Tier A.

| Gate | Required evidence artifact | Status |
| --- | --- | --- |
| B-01 public acknowledged AX mutation | Reference NSTextView spike: read-tail-range without selection, then select-tail/replace-tail; measure notification ordering/coalescing, self-vs-user origin ambiguity, and transport versus acknowledgement. If ambiguity remains, Tier A is not shippable. | **Failed** — [native reference evidence](reviews/evidence/live-insertion-native-reference-2026-07-26.md) found public transport success but no origin/acknowledgement, and no observer delivery in the self-owned fixture. Blocks Tier A API/UI. |
| B-02 same-offset substitution | Privacy-reviewed ranged-read spike and adversarial proof that same-length replacement at the same range is detected before selection or the next write. | **Reference property passed; gate remains open** — the native self-owned control detects the substitution without changing selection, but it does not prove the verify/select race or compensate for B-01's missing acknowledgement. Blocks ownership claim. |
| B-03 frozen-final delivery | Test evidence proving frozen-final emits zero AX writes and zero synthetic paste, with copy-only recovery. | Missing — blocks live settlement. |
| B-04 protected AX behavior | Secure-input × AX-write matrix for secure roles and IsSecureEventInputEnabled; determine whether the one pre-activation in-flight operation can land after protection. Result must establish rejection or force Tier D. | **Failed / unresolved** — native secure control activates secure event input; no protected-field AX write was attempted, and pre-activation residual behavior remains unproven. Tier D remains mandatory. |
| B-05 AX execution/liveness | Dedicated-run-loop observer and messaging-timeout experiment against deliberately hung target; timeout must fail closed within the mutation budget. | **Failed** — a 100 ms public messaging timeout returned success but a deliberately delayed self-owned AX read completed successfully in 503–510 ms. Blocks coordinator. |

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
                         ├ unsupported before a tail write ─→ fallback-final → existing single-shot final attempt → idle
                         ├ secure input/role ───────→ secure-final → copy-only / HUD recovery → idle
                         └ ownership loss ───────→ frozen-final → copy-only / explicit approved recovery → idle
~~~

tail-throttled is a live-lease substate: the existing capped tail remains untouched, later provisional content is HUD-only, and no further live field write is attempted. On stop, it routes to settle-owned-tail only when ownership is re-proven; otherwise it routes to frozen-final. It never routes directly to fallback-final because a tail was already written. fallback-final is reachable only before a live tail is written **and only while neither secure role nor secure input is active**. A secure-input transition, including with no tail or a throttled no-tail state, seals a distinct secure terminal: it does not route through single-shot final delivery, performs no automatic insertion, and exposes copy/HUD recovery only. Where automatic insertion is available, fallback-final uses the current settled field string: final transcript plus one ASCII trailing space. frozen-final is reachable after any tail write whose ownership cannot be re-proven. It leaves residual field text untouched, performs no automatic final insertion, and offers only copy until the user explicitly chooses an approved recovery. It never delivers full final text blindly at the current cursor. Every terminal route is consumed exactly once; repeated Stop is a no-op and cannot repeat fallback, settlement, frozen recovery, or secure recovery.

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
| C — single-shot final | Terminal/PTY, editors, rich text/IME, remote desktop, unknown/custom controls, and uncertified web/Electron. HUD updates; current single-shot final path only. |
| D — protected/unavailable | Missing Accessibility, no focus, read-only/password/secure role, secure input, or AX failure. No AX mutation, no synthetic event, no provisional clipboard write. Final copy/HUD recovery only. |

Secure role includes AXSecureTextField/AXTextFieldSecure and any certified equivalent. IsSecureEventInputEnabled is not an AX-write permission grant: no AX write is allowed until B-04 empirically proves behavior. The shipped single-shot final path leases the intended field and selection and requires bounded caret/content acknowledgement before clipboard restoration. Focus drift before dispatch and secure input leave final text copied. Timeout or target loss leaves it copied only while Saymark retains clipboard ownership; ownership loss preserves the newer user copy, the HUD reports failure, and only an eligible committed history row can recover the final text. The path also skips snapshot/restoration when the pasteboard carries org.nspasteboard.ConcealedType or org.nspasteboard.TransientType so Saymark never republishes such content.

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
| LI-U42 | Unit | Efficient and Tier C issue zero provisional/live mutations; HUD-only and Tier D issue zero AX mutations and zero synthetic events. |
| LI-U43 | Unit | Ownership verification reads kAXStringForRangeParameterizedAttribute without mutating selection; unavailable ranged read rejects Tier A. |
| LI-U44 | Build/unit gate | LiveInsertionPolicy has an empty import/dependency allowlist and rejects Foundation/CoreFoundation/XPC/IPC, AX, event, dynamic-link, Objective-C, process, and network escape hatches through negative fixtures. |
| LI-U45…U49 | Unit/property | Exact-once terminal routing; secure no-tail/no-tail-throttled copy-only terminal; mutation-token-bound tail acknowledgement; exact UTF-16 identity; separator/trailing-whitespace preservation. |
| LI-U50…U52 | Unit/async/property | Oversized hypothesis bounded retention; task-scheduled invalidation cannot revive the tracker; counter exhaustion retires instead of wrapping. |
| LI-I01…I08 | Integration | Reference Tier A, correction/punctuation/long utterance, focus/cursor/user-edit loss. Blocked until B gates. |
| LI-I09…I11 | Real-app integration | Real Safari, Chrome, and a production Electron app via LiveInsertionRealTargetHarness: ten repetitions/version, exact final, ordered proof. Blocked until B gates. |
| LI-I12 | Real-app integration | Real Terminal/PTY and code editor: zero live operations; single-shot final delivery attempted once over ten repetitions and independently acknowledged. |
| LI-I13…I15 | Integration | Missing AX, secure/password/protected state, clipboard race: no protected AX/synthetic operation and recovery preserved. |
| LI-I16…I21 | UI | Hold/toggle/restart/quit, VoiceOver, keyboard-only, Reduce Motion, localized recovery. |
| LI-I22 | Integration | For a safe settled lease, live settled field string is byte-identical to the single-shot final transcript plus trailing space. |
| LI-I23 | Integration | Toggle-mode Stop HUD click is non-focus-stealing or freezes per approved recovery; never blind-settles. |
| LI-I24 | Integration | Hold-mode Tier B: zero modifier-contaminated synthetic events throughout a held chord. |
| LI-I25 | Integration | Concealed/transient pasteboard content is never snapshotted or republished by any restoration path. |
| LI-P01…P05 | Performance | Authoritative latency/resource gates, no queue growth, 20 warmed runs/target. |
| LI-P06 | Performance | N/T policy, max four-word revision depth, p95 revoked provisional words/s <= 2. |
| LI-P07 | Unit performance | 10,000 normal pure-policy updates: p95 <=1 ms and maximum <=5 ms; the opt-in harness records RSS/settled growth. |
| LI-R01…R03 | Reliability | 10,000 deterministic and 500 task-scheduled AX/hypothesis/invalidation schedules: no crash/deadlock/leak/post-cancel write or terminal revival. |
| LI-S01…S06 | Security | Reordered AX, check/write race, secure/clipboard race, diagnostics scan, static privacy review. |
| LI-S07 | Security | Deliberately hung target with 100 ms messaging timeout fails closed with no mutation; asserts all AX I/O runs off-main. |

Before Tier A is unblocked, commit: B-01 spike result, B-02 adversarial read-back result, B-04 secure matrix, B-05 hung-target result, and real application evidence for its target. In-process compatibility fixtures alone are insufficient evidence for Safari, Chrome, Electron, or Terminal.

The shipped single-shot atomic-final path is certified against the versioned
[macOS 26.5.1 real-target matrix](reviews/evidence/atomic-insertion-target-matrix-2026-08-04.md).

## Implementation slices

1. **Policy core, no writes — permitted only behind a mechanical boundary:** create a separate LiveInsertionPolicy target for tokenizer/stability, lease/classifier/generation, throttle state, and typed telemetry schema. Its import allowlist is empty and its manifest declaration is zero-dependency: it may not import or reach Foundation/CoreFoundation/XPC/IPC, ApplicationServices, AppKit/Cocoa, CoreGraphics, dynamic-link/Objective-C, process, or network APIs. Before policy code lands, add a CI boundary test/gate with negative fixtures; LI-U44 verifies that gate. This target owns no AX adapter and has no production mutation path.
2. **Evidence spikes — not implementation:** produce B-01/B-02/B-04/B-05 artifacts. Failure retains Tier C/D; it does not weaken the safety contract.
3. **Tier A coordinator — blocked:** only after all B evidence, security review, and D-01…D-06 approval.
4. **Product integration — blocked:** only after Tier A is certified; opt-in first.
5. **Tier B certification/promotion — blocked:** only after Tier A, real-app results, D-07 if hold mode is requested, user testing, and final review.

### Slice 1 implementation invariants (2026-07-26)

The approved Slice 1 policy core is intentionally more restrictive than the
future coordinator design. It has no external write capability, and a positive
lease classification is an **evidence-only candidate**, not mutation authority.
The following invariants are implemented and regression-tested before any
evidence spike or adapter work:

- A recogniser-stable prefix is only a candidate. It becomes committed after a
  matching, current-generation acknowledgement; stale acknowledgements are
  ignored.
- Frozen-final is sticky. Further hypotheses, stop requests, or a claimed good
  ownership result cannot revive it; only explicit new-session reset can.
- Tail throttling snapshots the acknowledged field prefix and tail. All later
  hypotheses are HUD-only and cannot schedule another stable mutation.
- Stop routing reads sealed session-owned state, not a caller-provided tail
  boolean. Any acknowledged tail, including one followed by secure-input
  activation, can settle only with ownership proof or remains frozen; it cannot
  take atomic fallback. The old compatibility stop shim was removed, so no
  caller can forge tail history at stop time; terminal delivery is exact-once
  and repeated Stop is a no-op.
- Secure-input activation seals a copy-only terminal in every non-consumed
  state, including frozen ownership-loss and all no-tail/throttled states. It
  never selects fallback-final; repeated Stop is a no-op after copy-only.
- A field-resident tail acknowledgement is an opaque receipt carrying the
  request's exact UTF-16 candidate prefix and exact expected tail. It is
  retained only when the observed tail matches exactly and is <=64 UTF-16 code
  units; arbitrary, oversized, delayed, duplicate, or stale receipts fail. A
  new hypothesis retires every in-flight receipt, including an identical-text
  observation.
- Exact hypothesis fragments preserve original whitespace, punctuation, Unicode
  scalars, and UTF-16 length. Comparisons use exact UTF-16 code-unit identity,
  never canonical Swift `String` equality. Whitespace is separately represented
  so a later separator/trailing whitespace extends a committed prefix rather
  than falsely replacing it.
- Time observations clamp monotonically; generation/serial counters retire on
  exhaustion rather than wrap; pending recogniser work is capacity-one,
  latest-wins. Inputs exceeding the 64-code-unit tail cap throttle before
  fragment expansion, so HUD-only overflow is not retained by the policy core.

The mechanical boundary uses an empty import allowlist: a pure-Swift policy
target needs no explicit imports, so Foundation, CoreFoundation, XPC/IPC, UI,
AX, dynamic-link, Objective-C, process-launch, and network escape hatches all
fail closed. Its manifest declaration remains zero-dependency. Negative
fixtures for AX/events/AppKit/dynamic lookup/Foundation/XPC execute in the gate,
so a weakened pattern fails CI.

## Approved UI/design contract

The recommended native macOS package was approved on 2026-07-26. This approval
resolves D-01…D-07 but does not waive B-01…B-05 or authorize Slices 2–5 before
their evidence gates pass.

| Decision | Approved behavior |
| --- | --- |
| D-01 setting/default | Keep single-shot final-on-release as the safe default. “Insert while I speak” is an explicit opt-in, and its consent says provisional words are written into the active app and may change before settling. Unsupported fields automatically use final-on-release. |
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

## Recording evidence

The release evidence recording is
[`videos/live-insertion-evidence.mp4`](videos/live-insertion-evidence.mp4).
It shows the focused policy and clipboard-restoration tests passing, followed
by the native DEBUG daily-driver integration host executing the production
single-shot final-delivery path: the host invokes one delivery attempt, its
simulated receiver acknowledges the final text, and the original clipboard is
restored. This is deterministic seam evidence, not real-target certification. A recording-only on-screen trigger
invoked the same deterministic key-down/key-up path because macOS rejected
synthetic global keystrokes from the capture process; that trigger was removed
before commit.

The exact-main local UI result, current limitations, and published video
checksums are recorded in
[`v1-manual-acceptance.md`](v1-manual-acceptance.md).

This recording is intentionally **not** evidence that cross-application partial
live insertion ships. Slice 1 remains fail-closed, external provisional
mutation remains denied, and Slices 2–5 remain blocked by the evidence gates
above.
