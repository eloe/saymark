# Saymark 1.0 no-fee manual acceptance evidence

**Evidence date:** 2026-08-04  
**Release candidate main:** `c53561fa7616b4376f1fa3349173d2ddb720d5bf`  
**Reference Mac:** Mac Studio (Mac16,9), Apple M4 Max, 36 GB  
**Toolchain:** macOS 26.5.1 (25F80), Xcode 26.6 (17F113), arm64

This package records only tests that actually ran. It does not claim live-model,
multi-display, paid Apple distribution, notarization, or statistical evidence.
All visible sample values are synthetic. No private audio, transcript, selected
text, focused-field contents, clipboard contents, credentials, or personal data
is published.

## Local automation and exact-main result

Developer Mode and the required local macOS permissions were enabled without an
Apple Developer Program membership. From a clean branch at the exact main
revision above, the documented command was run with Full Keyboard Access set to
`AppleKeyboardUIMode=3` for the UI process and restored afterward:

```bash
mise exec -- make test-integration
```

The suite executed ten tests with zero failures or skips. The authoritative
local result is
`/tmp/saymark-ui-tests/Logs/Test/Test-Saymark-2026.08.04_11-26-58--0700.xcresult`;
average peak physical memory was 31.2 MB, average absolute physical memory was
31.13 MB, and average CPU time was 0.3 ms for the measured idle samples. It covers first-run
onboarding, reverse-Tab focus from the native shortcut recorder, the real Carbon
shortcut callback through the deterministic daily-driver host, exactly-once
delivery, clipboard restoration and newer-copy preservation, Accessibility and
secure-input copy-only fallbacks, no-speech behavior, a four-adapter/ten-run
compatibility matrix, and idle CPU/memory metrics. The `.xcresult` path and
summary are recorded in the pull request and issue close-out comments; local
paths are intentionally not represented as remotely downloadable artifacts.

The UI-test boundary replaces microphone input, model inference, TCC prompts,
and receiving third-party applications. The real AppKit/SwiftUI UI, state
machines, registered shortcut callbacks, HUD/delivery lifecycle, paste policy,
clipboard guard, accessibility tree, and app lifecycle execute. This is
deterministic integration evidence, not live transcription evidence.

## Onboarding acceptance (#38)

The first-launch and returning Setup-tour flows were completed with actual
VoiceOver and Full Keyboard Access on the reference Mac. The run covered Welcome,
real permission status, shortcut selection, preparation, Try It, Finish, closing,
reopening, and returning-tour lifecycle. VoiceOver could identify and operate the
controls without hidden duplicates; keyboard focus reached the native recorder
and reverse-Tab moved to Continue. Exactly one authoritative setup window and
menu process remained after completion/reopen. VoiceOver and the temporary
keyboard preference were turned off/restored after the run.

Real production-boundary status showed Microphone and Accessibility as Allowed.
Automated cases separately cover the safely skippable Accessibility consequence
and copy-only recovery. Light, dark, Increased Contrast, and Reduce Motion were
inspected. macOS did not expose Saymark as a per-app text-sizing target, so that
setting is not claimed. The reference Mac reported one display; multi-display
placement is explicitly unverified rather than inferred.

The synthetic walkthroughs are:

- [`videos/onboarding-evidence.mp4`](videos/onboarding-evidence.mp4) — first-run
  flow at source revision `149955b6d992122edbf958b2c0054140b45efa27`.
- [`videos/onboarding-reduce-motion-evidence.mp4`](videos/onboarding-reduce-motion-evidence.mp4)
  — Reduce Motion at the same revision.

The later reverse-Tab correction is proven on exact main by the local and hosted
`testShortcutRecorderReverseTabFocusesContinue` result and by PR #62's focused
review. The earlier videos are not relabeled as having run later code.

## Vocabulary acceptance (#31)

Keyboard and VoiceOver review covered empty/populated lists, search, add/edit,
enable/disable, delete, import preview, legacy schema-v1 migration, schema-v2
export, future-schema recovery, and corrupt retained-data recovery. Controls
exposed accurate labels/values/help and usable focus order. Appearance,
Increased Contrast, and Reduce Motion remained legible.

Executable/manual checks established these boundaries:

- schema v1 previews and imports into schema-v2 semantics;
- schema v2 exports with POSIX mode `0600`;
- a future schema is read-only and exports byte-for-byte unchanged at `0600`;
- corrupt retained data remains a truthful non-editable recovery state;
- the public UI/documentation says deterministic correction and does not claim
  pronunciation training or model-native biasing.

The synthetic walkthrough is
[`videos/vocabulary-language-correction-evidence.mp4`](videos/vocabulary-language-correction-evidence.mp4),
recorded at source revision `149955b6d992122edbf958b2c0054140b45efa27`.

## Recent Dictations and daily-driver evidence (#29)

[`videos/recent-dictations-evidence.mp4`](videos/recent-dictations-evidence.mp4)
shows three synthetic local records, detail, search, and delete confirmation at
source revision `149955b6d992122edbf958b2c0054140b45efa27`. Production Recent
Dictations opts out of capture; this recording used the existing DEBUG-only
capture boundary and contains no private history.

[`videos/live-insertion-evidence.mp4`](videos/live-insertion-evidence.mp4) is the
older hosted deterministic daily-driver walkthrough retained for its bounded
claims. Exact-main local and hosted UI runs are the authoritative 1.0 evidence
for current shortcut, delivery, fallback, focus, privacy, and clipboard behavior.
The independently reviewed real-target matrix remains separately documented in
[`reviews/evidence/atomic-insertion-target-matrix-2026-08-04.md`](reviews/evidence/atomic-insertion-target-matrix-2026-08-04.md).

## Checksums

SHA-256 values for every published video are committed in
[`videos/SHA256SUMS`](videos/SHA256SUMS). Recompute with:

```bash
shasum -a 256 -c docs/videos/SHA256SUMS
```
