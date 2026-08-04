# Native application integration testing

Saymark uses XCUITest for macOS application automation. It is the direct Apple
framework underneath Appium's Mac2 driver, works in the existing Xcode/Tuist
toolchain, and records target-app CPU and physical-memory metrics without a Node
server or WebDriver bridge.

## Run

```bash
make test-integration
```

The target generates a separately identified local app, signs the app and test
runner ad hoc, runs on the local arm64 Mac, and prints a compact test and resource
summary from the resulting `.xcresult` bundle.

## Test boundary

`SAYMARK_UI_TESTING=1` is honored only by Debug builds and injected only into the
test-launched process. It replaces
external side effects that are unsuitable for a repeatable test:

- macOS microphone and Accessibility prompts;
- multi-gigabyte model downloads and warm-up;
- live microphone capture and transcription;
- menu-app bootstrap and update checks after onboarding.

The real AppKit window, SwiftUI views, onboarding state machine, navigation,
accessibility tree, copy, and lifecycle remain in the test. The first-run test
runs with **Press to Start/Stop**, verifies that the first shortcut press enters
listening, and requires a second press before success and Finish. Hosted app
tests separately verify that the blue halo is exclusive to Start/Stop mode,
leaves during processing, resolves green on success, and is absent for Hold
mode and errors.

Model correctness and resource behavior are covered separately by the 20-run
SaymarkKit benchmark gates; an installed local Release build is covered by
`Scripts/check-app-resources.sh`.

Use stable accessibility identifiers for custom controls. A visible label may be
used when asserting product copy, because changing that copy should intentionally
require updating the test.

## Real single-shot target matrix

`Scripts/run-atomic-insertion-target-evidence.sh` exercises the production
`FocusedInsertionLease` and acknowledged single-shot `TextInjector` against the
currently focused real control. It does not transcribe audio, automate app
launches, inspect arbitrary field contents, or enable provisional mutation.

Use a blank document or synthetic field. The harness requires an explicit
`YES` before replacing the clipboard with a known synthetic marker, gives the
operator a countdown to focus the target, then attempts ten distinct synthetic
final pastes. Each run must receive the exact bounded AX receipt and restore the
synthetic clipboard marker. Output contains only environment/app/control
metadata (including bundle marketing/build versions), result categories,
timings, and restoration booleans; it never prints
the inserted token or any observed field/clipboard value.

```bash
Scripts/run-atomic-insertion-target-evidence.sh --build-only
Scripts/run-atomic-insertion-target-evidence.sh --control plain-single-line
```

`--build-only` verifies provenance and compilation without opening a permission
prompt or changing the clipboard. Use the second command only while present at
the Mac and ready to focus a synthetic target.

The first run may open Privacy & Security → Accessibility for the exact local
harness identity. The wrapper refuses uncommitted compiled sources, captures one
Git revision, compiles immutable source blobs from that revision, and keys the
binary to those blobs, the build script, compiler, and compile contract,
including the selected SDK. It emits the persisted build
metadata, ad-hoc CDHash, and SHA-256 rather than relabeling a cached executable
with the current toolchain. Every invocation re-verifies the signature and both
identifiers before requesting a permission or touching a target.
The recorded revision is therefore the code that ran, while
the same identity can be reused across unchanged target runs. Granting that
local permission is free and does not require an Apple ID,
Developer Program membership, signing identity, or notarization. Rerun the same
command after consent. A target is certified only when all ten runs
report `pasted`, exact acknowledgement, and clipboard restoration. Any missing
lease, secure-input state, focus change, timeout, unconfirmed delivery, or event
failure or any focus move to another control classifies that exact
app/control/version as fallback-only; do not weaken the
production policy to turn a red target green.

Record separate evidence for native single-line and multiline fields, Safari
web fields, installed Electron controls, rich editors, and Terminal. Use only
locally available applications and synthetic content; absence of a target class
must remain explicit rather than prompting an unapproved installation.
