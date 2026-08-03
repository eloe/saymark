# Architecture

Saymark is a native macOS menu-bar application with a reusable Swift package for
the dictation pipeline.

For a complete system map, use the
[interactive architecture page](architecture.html). Its canonical,
machine-readable source is [`architecture.json`](architecture.json), which is
structured as a handoff for future agents and repository tooling.

## Components

- **Saymark app** (`Sources/Saymark`) owns onboarding, settings, the menu bar,
  hold and Start/Stop hotkey behavior, HUD and listening-halo presentation, and
  application lifecycle.
- **SaymarkKit** (`SaymarkKit/Sources/SaymarkKit`) owns microphone capture,
  speech gating, model orchestration, transcript updates, finalization, and text
  insertion. It also owns deterministic Vocabulary correction and the guarded
  SQLite Recent Dictations store.
- **saymark-cli** uses the same core for repeatable model benchmarks without the
  application UI.

## Dictation lifecycle

1. The app loads the selected model plan before dictation begins.
2. Pressing the hotkey presents the HUD immediately and starts microphone
   capture. Start/Stop mode also shows a click-through edge halo on the active
   display.
3. Audio is processed in bounded increments while the key remains held or until
   the Start/Stop shortcut is pressed again. Live capture stops at 10 minutes;
   more than 5 seconds of queued/active audio fails closed as overload. These
   microphone safety bounds do not limit future offline-file transcription.
4. Live Preview may publish provisional Nemotron text during capture.
5. Releasing the key in Hold mode, or pressing it again in Start/Stop mode,
   stops capture and asks Parakeet for the authoritative final text. The blue
   halo disappears during processing and briefly resolves green after a
   successful Start/Stop result.
6. The frozen Vocabulary snapshot deterministically corrects the final text.
7. For in-field delivery, Saymark revalidates the Accessibility element,
   process, and selection leased at dictation start. It posts one final paste
   only while that intent remains current, then requires bounded caret and
   content acknowledgement before restoring the clipboard. Focus/selection
   drift before dispatch and secure input leave final text copied. Timeout or
   target loss leaves it copied only while Saymark still owns the pasteboard;
   clipboard ownership loss instead preserves the newer user copy. The HUD
   communicates the failure; only an eligible committed Recent Dictations row
   can recover the final text, so recovery is unavailable when history did not
   commit it. No case posts a late retry. HUD-only mode performs no external insertion.
8. If Recent Dictations was explicitly enabled at both start and finalization,
   eligible non-secure final text and its closed delivery outcome enter the
   local text-only history; no audio, provisional text, target, or clipboard
   content is retained.
9. Capture, subscriptions, timers, and HUD resources are torn down; loaded model
   residency is managed separately from per-dictation resources.

## First-run setup

Onboarding is a fixed 680 × 500 titled Mac window with five visible positions:
Welcome, Permissions, Shortcut, Prepare, and Try It. Microphone access is
required; Accessibility may be deferred. The permission screen invokes the
macOS Accessibility setup prompt and provides a draggable Saymark application
icon for the System Settings app list.

The shortcut screen chooses both the real global shortcut and either **Hold to
Dictate** or **Press to Start/Stop**. Try It accepts only that configured
gesture, displays the live transcript in its field, and unlocks Finish after a
non-empty result. Start/Stop practice uses the same active-display halo as the
normal dictation flow. There is no substitute Try button or separate completion
screen. One process-wide hotkey router transfers exclusive ownership between
onboarding and runtime only after capture, final delivery, and model work are
quiescent.

## Product modes

- **Efficient** loads the final model and produces text on release.
- **Live Preview** adds provisional streaming feedback, while retaining the same
  final-model authority.
- **Fast** is an internal diagnostic profile and is not a normal user choice.

Model pairs are product policy rather than arbitrary user configuration. Changes
must pass the quality, latency, CPU, and memory gates in
[`performance-acceptance.md`](performance-acceptance.md).
Changing modes during an active dictation defers preparation without changing
the recording lifecycle; requests coalesce latest-wins and apply after teardown.

Vocabulary is a separate local post-ASR correction stage, not a speech-model
choice. Recent Dictations is an opt-in recovery store, not a recording archive.
Cross-application provisional mutation is not shipped: Live Preview shows its
draft in Saymark's HUD and the single-shot final path remains authoritative.

## External boundaries

- macOS supplies microphone and Accessibility permissions.
- MLX executes local inference on Apple silicon.
- Hugging Face hosts model artifacts downloaded during setup.
- No audio or transcript text belongs in diagnostics or analytics.
