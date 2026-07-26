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
  insertion.
- **saymark-cli** uses the same core for repeatable model benchmarks without the
  application UI.

## Dictation lifecycle

1. The app loads the selected model plan before dictation begins.
2. Pressing the hotkey presents the HUD immediately and starts microphone
   capture. Start/Stop mode also shows a click-through edge halo on the active
   display.
3. Audio is processed in bounded increments while the key remains held or until
   the Start/Stop shortcut is pressed again.
4. Live Preview may publish provisional Nemotron text during capture.
5. Releasing the key in Hold mode, or pressing it again in Start/Stop mode,
   stops capture and asks Parakeet for the authoritative final text. The blue
   halo disappears during processing and briefly resolves green after a
   successful Start/Stop result.
6. Saymark inserts that text into the focused application or leaves it in the HUD,
   according to the selected insertion mode.
7. Capture, subscriptions, timers, and HUD resources are torn down; loaded model
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
screen.

## Product modes

- **Efficient** loads the final model and produces text on release.
- **Live Preview** adds provisional streaming feedback, while retaining the same
  final-model authority.
- **Fast** is an internal diagnostic profile and is not a normal user choice.

Model pairs are product policy rather than arbitrary user configuration. Changes
must pass the quality, latency, CPU, and memory gates in
[`performance-acceptance.md`](performance-acceptance.md).

## External boundaries

- macOS supplies microphone and Accessibility permissions.
- MLX executes local inference on Apple silicon.
- Hugging Face hosts model artifacts downloaded during setup.
- No audio or transcript text belongs in diagnostics or analytics.
