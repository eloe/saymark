# Live insertion native reference evidence — 2026-07-26

**Scope:** Slice 2 evidence only. This is a self-owned native macOS control
experiment, not a Saymark product implementation or a certification of another
application. No production source gained an AX mutator, AX observer, or
synthetic-event path.

**Overall result:** B-01, B-04, and B-05 **fail**. B-02's narrow self-owned
reference-control property passes, but does not close the ownership gate in the
presence of the B-01 acknowledgement failure. Tier A remains blocked; the
shipped atomic Tier C/D contract remains the only delivery policy.

## Reproduction and environment

| Item | Recorded value |
| --- | --- |
| Date | 2026-07-26 |
| OS | macOS 26.5.2 (build 25F84) |
| Hardware | Apple M2, arm64 |
| Toolchain | Swift 6.3.3 (`swiftlang-6.3.3.1.3`) |
| Xcode | No full Xcode selected; active developer directory was `/Library/Developer/CommandLineTools`; `xcodebuild -version` therefore could not run. |
| Fixture | A visible self-owned `NSTextView`, `NSSecureTextField`, and deliberately slow `NSTextView` in `LiveInsertionNativeReferenceHarness`. |
| Accessibility trust | `false`; the current process can still expose its own AX elements. This is specifically not evidence about a trusted cross-application client. |
| Commit before evidence | `c308b2b` |

Run from the repository root:

```sh
Scripts/check-live-insertion-evidence-safety.sh
Scripts/run-live-insertion-native-evidence.sh | tee /tmp/live-insertion-evidence.log
Scripts/check-live-insertion-evidence-result.sh /tmp/live-insertion-evidence.log
```

The harness source is
[`Evidence/LiveInsertionNativeReferenceHarness.swift`](../../../Evidence/LiveInsertionNativeReferenceHarness.swift).
It compiles directly with the Command Line Tools and has no package product.
The safety check rejects AX mutation/observer/timeout primitives anywhere under
production `Sources/`; the result checker asserts the expected *blocked* state,
not a false green gate.

## Test-only design and privacy boundary

The harness owns every window and control it accesses. It never addresses a
PID other than its own, never uses a pasteboard or synthetic input, and never
prints the ranged-read value. The only actual AX setters are limited to the
self-owned normal `NSTextView` for B-01 transport observation. The secure
matrix uses `SafeMutationAdapter`, a test-only adapter deliberately containing
no `AXUIElementSetAttributeValue` call; its protected-field AX-write count is
recorded as zero. The same-length substitution is made through a local native
fixture adapter, not through production text injection.

The ranged value is compared only in memory to the known fixture token and
discarded. The log reports booleans and AX result names only, never tail text.

## Results

### B-01 — public acknowledged AX mutation: FAIL

The public AX select and selected-text replace operations both returned
`kAXErrorSuccess` against the self-owned `NSTextView`. That is only transport
success. The public observer callback carries neither an origin nor a mutation
token/acknowledgement field. Across five runs, the dedicated run-loop observer
received zero notifications after the select/replace sequence, so there was no
ordering signal to correlate in this fixture either.

**Decision:** `acknowledgement-usable=false`. A public acknowledged mutation
primitive has not been demonstrated. No Tier A API, coordinator, or UI work is
authorized.

### B-02 — same-offset substitution: local property PASS; gate remains open

The fixture establishes a collapsed unrelated caret, reads the known 5 UTF-16
unit tail through `kAXStringForRangeParameterizedAttribute`, and confirms the
caret range is unchanged. It then replaces that exact range with different text
of identical UTF-16 length through the local test adapter. The second ranged
read detects the mismatch while the caret remains unchanged.

All five runs reported:

| Assertion | Result |
| --- | --- |
| First ranged read | `kAXErrorSuccess` |
| Initial known tail matched | true |
| Same-offset/same-length substitution detected | true |
| Selection unchanged after initial read | true |
| Selection unchanged after mismatch read | true |

This establishes the minimal read-only detection property in the native
reference control. It does **not** close B-02 for a product target: the test
does not establish atomicity between verification and a later selection/write,
and B-01 cannot provide acknowledgement/origin ordering. The SDD's fail-closed
rule therefore remains unchanged.

### B-04 — protected AX behavior: FAIL / unresolved

Focusing the self-owned `NSSecureTextField` produced
`IsSecureEventInputEnabled=true`; its AX role reported `AXTextField` rather
than a distinguishable secure role in this environment. The safe adapter
admitted one normal synthetic record, rejected all three protected combinations
(secure role, secure input, both), and modelled exactly one residual operation
when protection arrived during an already-admitted operation. It made **zero**
protected-field AX write attempts.

| Matrix observation | Result |
| --- | --- |
| Secure event input with native secure control | true |
| Protected-field AX write attempts | 0 |
| Simulated in-flight residual operations | 1 |
| Native protected AX write attempted | false (intentionally) |

This deliberately does not attempt a write into a protected field. It proves
the harness and proposed admission rule do not authorize one; it cannot prove
whether a pre-activation real AX operation can land after protection becomes
active. **B-04 remains failed/unresolved.** Tier D applies whenever secure role
or secure input is observed.

### B-05 — observer execution and hung target: FAIL

`AXObserverCreate` and both registrations returned `kAXErrorSuccess`; the
observer source was added to a dedicated CFRunLoop thread. For the deliberately
slow self-owned control, `AXUIElementSetMessagingTimeout(element, 0.100)` also
returned success, but an off-main `kAXValueAttribute` read returned
`kAXErrorSuccess` after 503.54–510.35 ms across five runs—more than five times
the requested timeout. No `kAXErrorCannotComplete` was observed. The read did
run off-main in every run.

| Assertion | Result |
| --- | --- |
| Dedicated observer source added | true |
| Messaging timeout accepted | true |
| Delayed read completed off-main | true, 5/5 |
| Delayed read failed by 100 ms | false, 0/5 |
| Delayed read transport result | `kAXErrorSuccess`, 5/5 |
| Coordinator fail-closed evidence | false |

The self-owned control is an intentionally conservative test: it also cannot
certify how an independent process handles AX IPC. That limitation is not a
reason to relax the contract. **B-05 fails:** no future coordinator may rely on
the public timeout as a hard 100 ms cancellation boundary, and no mutation
path may be added.

## Five-run log summary

| Run | B-01 acknowledgement | B-02 mismatch/selection | Secure input | Protected AX writes | Hung read |
| --- | --- | --- | --- | --- | --- |
| 1 | false | true / unchanged | true | 0 | success, 507.44 ms off-main |
| 2 | false | true / unchanged | true | 0 | success, 510.10 ms off-main |
| 3 | false | true / unchanged | true | 0 | success, 503.54 ms off-main |
| 4 | false | true / unchanged | true | 0 | success, 508.47 ms off-main |
| 5 | false | true / unchanged | true | 0 | success, 510.35 ms off-main |

Representative raw run (the harness intentionally omits observed text):

```text
harness=self-owned-native-control
accessibility.trusted=false
secure-event-input.initial=false
normal.role=kAXErrorSuccess:AXTextArea
observer.create=kAXErrorSuccess
observer.add.selected=kAXErrorSuccess
observer.add.value=kAXErrorSuccess
observer.source.added=true
b02.sentinel.set=kAXErrorSuccess
b02.read.initial=kAXErrorSuccess
b02.selection.unchanged.after-read=true
b02.initial-tail-match=true
b02.same-offset.same-length.local-substitution-count=1
b02.read.after-substitution=kAXErrorSuccess
b02.substitution-detected=true
b02.selection.unchanged.after-mismatch-read=true
b01.public-select-transport=kAXErrorSuccess
b01.public-replace-transport=kAXErrorSuccess
b01.public-origin-field=false
b01.public-ack-token-field=false
b04.secure-event-input.with-secure-control=true
b04.protected-field.ax-write-attempts=0
b04.native-protected-write-tested=false
b05.timeout.set.hung=kAXErrorSuccess
b05.hung-read.error=kAXErrorSuccess;elapsed=508.89;off-main=true
b05.coordinator-fail-closed-evidence=false
b01.observer.notification-count=0
b01.acknowledgement-usable=false
```

## Required disposition

1. Keep B-01, B-04, and B-05 **failed** and B-02 **unclosed** in the SDD.
2. Keep Tier A and Tier B disabled. Do not add cross-app AX mutation, synthetic
   live input, live-insertion UI, or Slices 3–5.
3. The future research question is not “how to work around this timeout.” It is
   whether a supported design can establish acknowledgement, ordering, and a
   real cancellation/fail-closed boundary. Until then, use the atomic final
   contract or copy/HUD recovery.

## Test mapping

| SDD IDs | Artifact coverage |
| --- | --- |
| LI-U35 / LI-U43 | Read-only bounded range and same-offset substitution proof, with selection invariance. |
| LI-U37 / LI-U38 | Secure admission matrix and one-in-flight residual model; native protected write intentionally prohibited. |
| LI-S07 | Dedicated CFRunLoop observer, off-main AX read, 100 ms messaging-timeout experiment, and negative fail-closed result. |
| B-01 | Public setter transport/observer origin-and-acknowledgement negative result. |
