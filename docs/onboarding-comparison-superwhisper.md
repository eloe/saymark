# Saymark and Superwhisper onboarding

Current comparison and remaining design gaps

24 July 2026

## Conclusion

Saymark's onboarding no longer feels primarily like Murmur. The current working
tree has already made the important structural change: it is a restrained,
linear Mac setup flow with one task per screen, native controls, system
typography, direct language, and little decorative motion.

The earlier Murmur-like qualities have been removed:

- no narrator rail or speech bubble;
- no first-person assistant voice;
- no typewriter performance or mascot animation;
- no serif display hierarchy;
- no card-and-chip showcase;
- no separate Done page and finished overlay;
- no substitute hold button as the primary lesson.

Compared with Superwhisper, Saymark now has the cleaner and more conventionally
Mac-like information architecture. Two activation gaps remain:

1. The roughly 2.5 GB model preparation remains a blocking setup step.
2. The first-use screen proves the shortcut and pipeline, but it does not yet
   verify a real microphone level.

The direction should be to finish this native design, not to imitate
Superwhisper's dark branded style.

## Evidence and limitations

The Saymark findings come from the current working-tree implementation,
including window construction, screen layout, controls, copy, model gates, and
try-it behavior.

Superwhisper's official documentation confirms that its setup covers
permissions, language, local or cloud model choice, microphone configuration,
shortcut guidance, and a first dictation. Its current public welcome screenshot
is minimal and brand-led. More detailed public setup screenshots come from an
older third-party review, so they are useful for flow comparison but not as a
pixel-accurate representation of the July 2026 build.

## Direct comparison

| Dimension | Saymark now | Superwhisper | Remaining Saymark opportunity |
| --- | --- | --- | --- |
| Window | Fixed 680 × 500 standard titled window | Custom branded window; minimal current welcome | Validate every state and accessibility size |
| Structure | 188-point native setup sidebar, scrollable task content, fixed footer | One central task per screen | Keep Saymark's current structure |
| Progress | Five-step sidebar with current and completed states | Minimal visible progress on welcome | Current treatment is appropriately quiet |
| Brand presence | Production Saymark mark in sidebar and onboarding | Strong branded mark as focal element | Validate compiled and small-size rendering |
| Typography | System sans-serif hierarchy | Large branded sans-serif headings | Preserve the current native hierarchy |
| Voice | Direct tool language | Direct task language | Preserve; avoid returning to assistant personality |
| Controls | Native buttons, form, segmented picker, progress bar, and group boxes | Mostly conventional controls within a custom visual system | Continue using semantic macOS controls |
| Color | System surfaces and restrained blue accent | Dark custom monochrome field | Saymark is now more conventionally macOS |
| Motion | Limited to real progress, listening, and success states | Brand and toast/card motion | Keep motion tied to product state |
| Permissions | Two native rows with state and explicit actions | Setup includes permission guidance | Saymark is clear and compact |
| Shortcut | Real recorder plus Hold to Talk / Press Once | Guided shortcut configuration | Saymark directly exposes its key product distinction |
| Model setup | Blocking local download with one progress view | Local/cloud model selection and a skip path | Reduce blocking without exposing model machinery |
| First use | Teaches the configured global shortcut; button is fallback | Guided first dictation | Add real signal verification |
| Completion | Inline success in Try It, then Finish | Setup verification then entry | Current Saymark pattern is concise |

## What is already resolved

### The app is no longer presented as a character

The old “Hi, I'm Saymark,” “my voice,” and speech-bubble presentation are gone.
The mark no longer performs as a mascot. Current copy describes the tool and the
required action directly.

### The hierarchy is no longer duplicated

Each screen now has one task region and one footer. A restrained native-style
sidebar communicates the five steps and their current/completed state without a
second title system, narrator rail, or oversized custom stepper.

### The components now read as a Mac utility

Permissions use native group boxes and buttons. Shortcut behavior uses a real
recorder, `Form`, and segmented picker. Download uses a standard
`ProgressView`. The warm illustrated-wizard aesthetic has been removed.

### The flow teaches the real interaction

Try It subscribes to the configured global shortcut and changes its instruction
for hold versus toggle behavior. “Try with Button” is now a fallback rather than
the main lesson.

### Completion happens once

The `.done` state is rendered inside Try It as “Saymark is ready,” followed by a
single Finish action. The previous separate completion page and overlay are
gone.

## Remaining gaps

### P0 — Validate standard window chrome

`AppDelegate` now creates a fixed 680 × 500 standard titled window. The prior
full-size transparent title bar, hidden title, and safe-area override are gone.

**Recommendation**

- Verify every screen fits at 680 × 500 in light mode, dark mode, and increased
  text size.
- Keep the standard “Saymark Setup” title, normal close behavior, and centered
  presentation.

### P0 — Validate identity integration

The repository now contains a complete app-icon set, a dedicated menu-bar
template asset, production vector masters, a Saymark social preview, and the
production mark in onboarding.

**Recommendation**

Validate the compiled catalog and small-size rendering. Keep compact status
symbols semantic where that is clearer than scaling the product mark.

### P1 — Reduce the blocking download

The simplified download screen is visually correct, but first activation still
waits for roughly 2.5 GB of local model data.

**Recommendation**

- Start preparation earlier after explicit user consent where architecture
  permits.
- Let permission and shortcut setup proceed while the download runs.
- Consider a Continue in Background path only if Saymark can remain safely
  inactive and communicate readiness clearly.
- Keep model names and roles out of first-run UI.

### P1 — Turn Try It into a microphone health check

The screen exercises the real transcription pipeline, which is stronger than a
decorative demo. It still cannot distinguish silence, the wrong input device,
or an unusable signal before transcription fails.

**Recommendation**

- Show a real input level while listening.
- Detect permission-with-no-signal.
- Offer input-device selection only when multiple devices are available.
- Keep the button fallback for accessibility and troubleshooting.

### P2 — Tighten residual custom styling

`SaymarkTheme` now mostly wraps semantic macOS colors and may no longer earn its
abstraction. The fixed footer bar is acceptable, but should be visually checked
at the smaller window size, in dark mode, with increased contrast, keyboard
navigation, and larger accessibility text.

## Recommended final specification

- Window: approximately 680 × 500, standard titled and closable Mac window.
- Content: 188-point setup sidebar plus a scrollable task pane and fixed footer.
- Progress: five-step sidebar with current and completed states.
- Typography: system title, title 3, body, callout, and caption styles.
- Surfaces: system window, control, separator, and bar materials.
- Accent: Saymark blue for the primary action and live state.
- Brand mark: production mark on Welcome and success; functional listening
  state in Try It.
- Motion: only recording, processing, download, and success feedback.
- Controls: default macOS controls and keyboard behavior.

## Priority

### P0 — Validate native presentation

- Exercise every onboarding state at 680 × 500 in light and dark appearance.
- Verify the production mark, keyboard navigation, VoiceOver labels, increased
  contrast, and larger accessibility text.

### P1 — Improve activation resilience

- Overlap model preparation with setup where safe.
- Add real microphone-level and no-signal verification.

### P2 — Validate polish

- Test dark mode, increased contrast, reduced motion, VoiceOver, keyboard-only
  navigation, long localization strings, and every permission/download error
  state.
- Update UI assertions or snapshots to match the five-position flow.

## Source references

### Saymark

- `Sources/Saymark/AppDelegate.swift`
- `Sources/Saymark/Onboarding/OnboardingView.swift`
- `Sources/Saymark/Onboarding/OnboardingChrome.swift`
- `Sources/Saymark/Onboarding/PermissionsScreen.swift`
- `Sources/Saymark/Onboarding/ShortcutScreen.swift`
- `Sources/Saymark/Onboarding/DownloadScreen.swift`
- `Sources/Saymark/Onboarding/TryItScreen.swift`
- `Sources/Saymark/Onboarding/OnboardingModel.swift`
- `SaymarkKit/Sources/SaymarkKit/OnboardingFlow.swift`
- `Tests/SaymarkUITests/OnboardingUITests.swift`

### External

- [Superwhisper introduction and setup summary](https://superwhisper.com/docs/get-started/introduction)
- [Superwhisper changelog](https://superwhisper.com/changelog)
- [Apple Human Interface Guidelines: Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- [Apple Human Interface Guidelines: Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
