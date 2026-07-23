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
accessibility tree, copy, and lifecycle remain in the test. Model correctness and
resource behavior are covered separately by the 20-run SaymarkKit benchmark gates;
an installed local Release build is covered by `Scripts/check-app-resources.sh`.

Use stable accessibility identifiers for custom controls. A visible label may be
used when asserting product copy, because changing that copy should intentionally
require updating the test.
