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

A separate real production-boundary run exercised the microphone denial and
retry path without replacing TCC. The first attempt displayed Saymark's real
microphone prompt in front of onboarding and denial returned to a recoverable
permission state. Retrying and allowing the permission produced
`microphone.permission granted=true`, verified the pinned model artifacts,
loaded the real Parakeet and VAD components, and delivered the production
shortcut callback. No transcription or insertion is claimed from this run:
System Information reported no audio input device, so synthetic speaker output
never entered capture. The temporary XCUITest driver and its privacy-unsafe
full-screen recording were deleted rather than published.

On 2026-08-10, a fresh app built from literal merged main
`58541a08130d8f7af37aa6ee152f6004fda0364c` naturally entered the real denied
Accessibility state; no TCC reset or review override was used. With actual
VoiceOver running, the permission screen exposed the Microphone and
Accessibility explanations, the “Drag Saymark into System Settings” recovery
instructions, the draggable Saymark icon and its help, “Set Up Accessibility,”
Back, and the “Set Up Later” outcome (which correctly could not advance while
the required microphone permission also remained denied). Invoking Set Up
Accessibility did not strand or duplicate onboarding: Saymark remained
frontmost and retained the recoverable denied-state instructions while polling
for a future grant. The separate granted-state production run above verifies
that returning with permission is reflected as Allowed. The privacy-safe
window-only denied-state capture is
[`evidence/v1/onboarding-accessibility-denied-58541a0.png`](evidence/v1/onboarding-accessibility-denied-58541a0.png).
VoiceOver and Saymark were quit afterward.

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

Supplemental exact-merged-main evidence was run on 2026-08-10 from a fresh
Debug build of `bc231523de00e29ec3d60c0d7a37e3a53a9f881b`. A temporary regular
file at the app's expected Application Support directory forced the real
`VocabularyStore` open to fail; the pre-existing empty directory and defaults
were preserved before the run and restored afterward. The Settings UI exposed
the full raw-text fallback error, a “Vocabulary storage unavailable” state, and
disabled Add, Import, and Export controls. Actual VoiceOver was started for the
focused pass: keyboard focus reached Search Vocabulary, skipped the disabled
actions, and the accessibility tree exposed the error and unavailable-state
copy. VoiceOver and its Quickstart were quit after the pass. This is evidence
for the unavailable-storage state.

The privacy-safe window-only capture is
[`evidence/v1/vocabulary-unavailable-storage-bc23152.png`](evidence/v1/vocabulary-unavailable-storage-bc23152.png).

A second bounded exact-main pass loaded one local synthetic rule and selected a
schema-v2 synthetic import whose differently cased “Say Mark” trigger normalized
to the same phrase. The real import-preview sheet reported one conflict, exposed
the normalized trigger and both fixed synthetic UUIDs, and disabled Import.
With actual VoiceOver running, the accessibility tree exposed the conflict count,
resolution instruction, trigger, both entry IDs, enabled Cancel, and disabled
Import. VoiceOver and Quickstart were quit and the original empty local store and
defaults were restored afterward. The privacy-safe window-only capture is
[`evidence/v1/vocabulary-import-conflict-bc23152.png`](evidence/v1/vocabulary-import-conflict-bc23152.png).
This evidence was supplemented after the accessibility correction merged. A
fresh Debug build from literal merged main
`58541a08130d8f7af37aa6ee152f6004fda0364c` rendered the production HUD in a
deterministic synthetic `failedRawFallback` state through source-free debugger
state injection; no source file, persisted user data, model, microphone, or
transcript was modified or claimed. Actual VoiceOver was running during the
bounded pass. The accessibility tree independently exposed the correction
summary, raw transcript, final transcript, an enabled “Correction details”
button with value “Expanded,” and a separate enabled “Copy raw transcript”
button. The privacy-safe window-only capture is
[`evidence/v1/vocabulary-raw-disclosure-58541a0.png`](evidence/v1/vocabulary-raw-disclosure-58541a0.png).
VoiceOver and Saymark were quit after the pass.

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
(cd docs/videos && shasum -a 256 -c SHA256SUMS)
```

Supplemental exact-main still-image checksums are committed in
[`evidence/v1/SHA256SUMS`](evidence/v1/SHA256SUMS). Recompute with:

```bash
(cd docs/evidence/v1 && shasum -a 256 -c SHA256SUMS)
```
