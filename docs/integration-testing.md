# Native application integration testing

Saymark uses XCUITest for macOS application automation. It is the direct Apple
framework underneath Appium's Mac2 driver, works in the existing Xcode/Tuist
toolchain, and records target-app CPU and physical-memory metrics without a Node
server or WebDriver bridge.

## Run

```bash
mise exec -- make ui-evidence-preflight
mise exec -- make test-integration
```

The preflight uses only local macOS/Xcode state and does not require an Apple
Developer Program membership, Apple ID, signing certificate, provisioning
profile, or notarization. It checks the supported OS/architecture, the selected
Xcode installation and first-launch setup, and whether Developer Mode is
enabled. If Developer Mode is disabled, run the printed
`sudo /usr/sbin/DevToolsSecurity -enable` command while present at the Mac; this
is a local administrator action and may request the Mac login password.
The preflight also verifies a compatible Xcode 26 installation and the
repository-pinned Tuist version. It prints a plain `make` next step when Tuist
is already active on `PATH`, or a `mise exec -- make` next step when the pinned
tool is available through mise.

The preflight cannot truthfully infer another executable's TCC grants.
Accessibility, Microphone, Automation, and Screen Recording consent belong to
the exact app or runner identity that macOS displays. Approve those prompts only
when the real Saymark/local evidence run requests them. A successful preflight
means the machine is ready to attempt XCUITest; the successful
`make test-integration` result remains the evidence that automation actually
executed.

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
