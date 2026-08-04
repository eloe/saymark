# Atomic insertion real-target matrix — 2026-08-04

## Scope and provenance

This record certifies Saymark's single-shot atomic-final insertion path against
real macOS controls. It does not claim provisional/live field mutation.

- Evidence revision: `c5e4006f8e39890710fb507be3a96d69072f6b5b`
- macOS: 26.5.1 (25F80)
- Hardware: Mac16,9, Apple silicon (`arm64`)
- Xcode: 26.6 (17F113)
- SDK: macOS 26.5
- Swift: 6.3.3, compiled in Swift 5 mode
- Harness build key: `09554ed1f9a071c422950051bcc2ef73a86c1e058564e2726f5201f730b9d548`
- Harness signature: ad hoc, no Team Identifier
- Harness CDHash: `eab525017483a66d0e760043bbb4684e112fa285`
- Harness SHA-256: `7e74e0d66a065c9e85d65882f2cca98f22e7d71d90bd50510f3492abf875bfa2`
- Web fixture SHA-256: `ec5bd7f87a5264726a9c972dbb3bbc98acd8aa338e358034573d1b78a6070923`

The harness was compiled from immutable Git blobs after an independently
reviewed checkpoint. Every invocation reverified the ad-hoc signature, CDHash,
SHA-256, build key, SDK, compiler, and exact revision before replacing the
clipboard with a synthetic marker. No Apple Developer membership, signing
identity, notarization, network service, audio, or real transcript was used.

## Certified targets

Every row completed ten repetitions. `certified-exact-once` means every run
reported `pasted`, received the exact bounded AX caret/content receipt, and
restored the synthetic clipboard marker. The harness emitted no field or
clipboard values.

| Application/control | Version/build | AX role/subrole | Result | Completed | Ack median | Ack p95 | Ack max | Clipboard restored |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| TextEdit rich multiline | 1.20 / 415 | `AXTextArea` / none | certified-exact-once | 10/10 | 52.99 ms | 69.35 ms | 69.35 ms | 10/10 |
| TextEdit plain multiline | 1.20 / 415 | `AXTextArea` / none | certified-exact-once | 10/10 | 51.78 ms | 53.37 ms | 53.37 ms | 10/10 |
| TextEdit Find single-line | 1.20 / 415 | `AXTextField` / `AXSearchField` | certified-exact-once | 10/10 | 54.92 ms | 123.43 ms | 123.43 ms | 10/10 |
| Safari web single-line | 26.5 / 21624.2.5.11.4 | `AXTextField` / none | certified-exact-once | 10/10 | 51.46 ms | 73.50 ms | 73.50 ms | 10/10 |
| Safari web multiline | 26.5 / 21624.2.5.11.4 | `AXTextArea` / none | certified-exact-once | 10/10 | 51.76 ms | 53.70 ms | 53.70 ms | 10/10 |
| Claude Electron composer | 1.24012.11 / 1.24012.11 | `AXTextArea` / none | certified-exact-once | 10/10 | 56.88 ms | 61.17 ms | 61.17 ms | 10/10 |
| Terminal shell prompt | 2.15 / 470.2 | `AXTextArea` / none | certified-exact-once | 10/10 | 51.22 ms | 80.34 ms | 80.34 ms | 10/10 |

The Safari controls used the exact checked-in `Evidence/SyntheticWebTarget.html`
fixture. The Claude contents were cleared without sending, and the Terminal
prompt was cleared with Control-U without executing a command.

## Failed evidence retained

The first two pre-fix TextEdit attempts at `1aeee2c` made no paste, preserved
the clipboard marker, and returned `target-identity-unavailable`. A content-free
probe showed TextEdit frontmost with a focused `AXTextArea`, while the production
system-wide focused-element query returned `kAXErrorCannotComplete` at 50, 100,
250, 500, and 1,000 ms. The frontmost-application AX query succeeded immediately.

The resulting production fix retains the system-wide query first, then falls
back to the frontmost application only when all of these remain true:

1. the frontmost PID is captured;
2. the app-scoped focused element is returned;
3. the element PID matches the captured PID; and
4. the frontmost PID is unchanged after the AX query.

An independent review found an A-to-B focus race in the initial fallback. The
second PID check and element-PID match closed it. Deterministic tests prove that
frontmost-app drift rejects the lease, posts no paste, and leaves the transcript
recoverable on the clipboard. The focused suite passed 22/22 after the fix, and
independent re-review found no remaining P0/P1.

One operator-timing attempt captured the Codex `AXTabPanel` instead of Claude.
It returned `delivery-unconfirmed`, did not restore over the synthetic recovery
token, and was excluded from certification. A delayed Claude activation then
captured the intended Electron `AXTextArea` and produced the certified row.

## Negative-path coverage

The real positive matrix supplements, rather than replaces, the deterministic
production-path coverage for focus/selection drift, secure-input transitions,
clipboard mutation, delayed acknowledgement, target loss, unresponsive AX
probes, same-length substitution, Unicode receipts, cancellation, and bounded
timeouts. These cases remain fail-closed: no late/retried paste is authorized,
and recoverable final text remains on the clipboard when delivery cannot be
proven.

## Privacy boundary

Only blank controls and synthetic tokens were used. This record contains no
audio, transcript text, clipboard values, selected text, focused-field values,
vocabulary, credentials, or personal information.
