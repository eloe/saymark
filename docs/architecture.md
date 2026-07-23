# Architecture

Saymark is a native macOS menu-bar application with a reusable Swift package for
the dictation pipeline.

For a complete system map, use the
[interactive architecture page](architecture.html). Its canonical,
machine-readable source is [`architecture.json`](architecture.json), which is
structured as a handoff for future agents and repository tooling.

## Components

- **Saymark app** (`Sources/Saymark`) owns onboarding, settings, the menu bar,
  hotkey behavior, HUD presentation, and application lifecycle.
- **SaymarkKit** (`SaymarkKit/Sources/SaymarkKit`) owns microphone capture,
  speech gating, model orchestration, transcript updates, finalization, and text
  insertion.
- **saymark-cli** uses the same core for repeatable model benchmarks without the
  application UI.

## Dictation lifecycle

1. The app loads the selected model plan before dictation begins.
2. Pressing the hotkey presents the HUD immediately and starts microphone capture.
3. Audio is processed in bounded increments while the key remains held.
4. Live Preview may publish provisional Nemotron text during capture.
5. Releasing the key stops capture and asks Parakeet for the authoritative final text.
6. Saymark inserts that text into the focused application or leaves it in the HUD,
   according to the selected insertion mode.
7. Capture, subscriptions, timers, and HUD resources are torn down; loaded model
   residency is managed separately from per-dictation resources.

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
