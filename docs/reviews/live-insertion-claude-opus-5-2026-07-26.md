# Claude Opus 5 independent review — live insertion

**Date:** 2026-07-26  
**Reviewer:** Claude Opus 5 High, read-only desktop review  
**Reviewed commit:** c175d25 on codex/live-insertion  
**Verdict:** APPROVE-WITH-CHANGES, scoped. Slice 1 policy core may proceed; any cross-application field mutation is blocked.

This record preserves the independent review and the disposition adopted in [live-insertion-sdd.md](../live-insertion-sdd.md). The original reviewer plan file was outside the repository and is not a source-controlled product artifact.

## Scope reviewed

The reviewer read the initial live-insertion design, TextInjector, DictationController, DictationSession, Accessibility, diagnostic logging, HUD and daily-driver harness, performance/privacy documentation, and existing injection/diagnostic/UI tests.

## Blocking findings and disposition

| Finding | Disposition | Required evidence before live mutation |
| --- | --- | --- |
| B-01 — no public acknowledged AX mutation primitive | Preserved as a hard pre-Slice-2 gate. Tier A API/UI is not committed. | Reference NSTextView spike measuring select/replace transport result, notification ordering/coalescing, and self/user origin ambiguity. Ambiguity means Tier A is not shippable. |
| B-02 — range equality cannot detect same-offset substitution | SDD permits a narrow selected-tail read-back of Saymark-authored text only, capped at 64 UTF-16 code units; it is immediately discarded and never logged. | Privacy review and adversarial same-length/same-offset substitution proof. |
| B-03 — blind atomic paste after lease loss duplicates/guesses | LI-05 now separates fallback-final from frozen-final. frozen-final permits zero AX writes and zero synthetic paste, with copy-only recovery. | LI-U36 / B-03 evidence and D-03/D-06 approval. |
| B-04 — secure input does not prove AX writes are safe | Protected state now forbids both synthetic events and AX mutation. Polling is 25 ms with 125 ms last-possible-mutation bound; secure AX behavior remains unassumed. | Secure-input × AX-write matrix for secure roles and secure event input. |
| B-05 — AXObserver/run-loop and synchronous IPC were unspecified | Future observer has a dedicated CFRunLoop thread; AX I/O is off-main with 100 ms messaging timeout and timeout fails closed. | Hung-target/timeout experiment and LI-S07. |

## High findings and disposition

| Finding | Disposition |
| --- | --- |
| H-01 residual provisional text | Added D-06; no implicit cleanup/replacement may occur after ownership loss. |
| H-02 held modifiers in Tier B | Tier B live synthesis is disabled in hold mode by default; D-07 and LI-I24 are required to change that. |
| H-03 toggle HUD Stop focus | Stop must be non-focus-stealing or frozen-final; LI-I23 explicitly verifies it. |
| H-04 unbounded telemetry values | New live fields must be typed closed enums/buckets in both diagnostics and PostHog; LI-U39 forbids bundle_id/free strings. |
| H-05 0.45 s streaming step versus 300 ms freeze | Performance acceptance now adds a <=300 ms streaming-step cap for live-insertion eligible targets. |
| H-06 no stability bound | SDD pins N=2 and T=160 ms, max four-word revision depth, p95 <=2 revoked provisional words/s; LI-P06 gates it. |
| H-07 final delta needs Saymark-owned content | SDD explicitly allows active-session in-memory retention of Saymark-authored tokens, never user text or persistence/logging. |

## Medium and low findings and disposition

| Finding | Disposition |
| --- | --- |
| M-01 fake compatibility matrix treated as proof | SDD calls atomic paste the current shipped contract and requires LiveInsertionRealTargetHarness evidence for real Safari, Chrome, Electron, Terminal. |
| M-02 trailing-space ambiguity | Safe live settlement is byte-identical to existing atomic final: final transcript plus one ASCII trailing space; LI-I22 added. |
| M-03 undo/redo omission | Both invalidate lease; LI-U40 added. |
| M-04 concealed/transient clipboard re-publication | Restore must be skipped for ConcealedType/TransientType snapshot; LI-U28 and LI-I25 added. |
| M-05 target lifecycle omission | Termination, closed document/window, and invalid AX element are named; LI-U41 added. |
| M-06 non-live regression omission | LI-U42 requires zero AX/synthetic operations in Efficient, HUD-only, Tier C/D. |
| M-07 duplicate timing table | SDD now links to the authoritative performance document rather than duplicating its table. |
| L-01 two telemetry sinks | Both diagnostics and PostHog are named and must use buckets/closed enums. |
| L-02 unspecified stability parameters | N/T are pinned provisionally and experiment-revisable. |
| L-03 embedded self-review prompt | Removed from SDD; this durable independent-review record replaces it. |

## Test IDs introduced by the review

LI-U35 through LI-U42, LI-I22 through LI-I25, LI-P06, and LI-S07 are required in addition to the existing test plan. They are traceable in the SDD.

## Remaining decision and evidence register

* All B-01 through B-05 evidence is **missing**.
* D-01 through D-07 require user design approval before user-facing live insertion work.
* Slice 1 may implement policy-only code with no production AX mutation or synthetic-input path.
* Slices 2 through 5 remain blocked. A failed evidence spike retains the atomic Tier C/D policy; it must not weaken ownership guarantees.

