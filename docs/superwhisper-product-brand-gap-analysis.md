# Saymark vs. Superwhisper

Product, brand, and design gap analysis

24 July 2026

## Executive summary

Saymark should not position itself as a smaller Superwhisper.

Superwhisper is becoming a broad voice-productivity platform: dictation, AI
rewriting, context-aware modes, file and meeting transcription, searchable
history, vocabulary, multiple local and cloud models, mobile and Windows apps,
enterprise controls, and agent integrations.

Saymark's credible opening is narrower:

> **The private, dependable voice-writing layer for Mac.**
>
> Hold a shortcut and speak naturally. Saymark writes at the cursor as you talk,
> then corrects its recent words as understanding improves—all locally.

That position is differentiated enough to win a specific audience, but the
current product does not yet prove it as clearly as it promises it. The most
important near-term work is:

1. Make safe, continuously correcting live insertion the core experience.
2. Validate the implemented identity in compiled and release artifacts.
3. Add transcript recovery without compromising local-first privacy.
4. State language support and publish measured product proof.
5. Complete signed and notarized distribution.

Custom AI modes, meetings, mobile apps, cloud models, and agent integrations are
real competitive gaps, but they are not the first gaps Saymark should close.

## What each product is selling

| | Saymark today | Superwhisper today |
| --- | --- | --- |
| Core job | Accurate system-wide dictation on Apple silicon | Voice as a general-purpose input and transformation layer |
| Primary promise | “Speak naturally. Write anywhere.” | Dictate, then automatically clean, format, translate, or transform |
| Product posture | Opinionated, local, minimal | Flexible, configurable, multi-model |
| Platforms | macOS 15+, Apple silicon | macOS, Windows, iPhone, and iPad |
| Privacy posture | Dictation fully on-device; diagnostics local by default | Local or cloud by user choice; formal enterprise trust program |
| Configuration | Two experiences: Efficient and Live Preview | Modes, models, languages, context, auto-activation, vocabulary, and API keys |
| Recovery | Final result is pasted or copied; no user-facing history | Local history, search, reprocessing, export, and issue reporting |
| Expansion jobs | HUD-only subtitles/presentations | Files, meetings, speaker separation, translation, snippets, CLI, and MCP |

Superwhisper wins on breadth and visible capability. Saymark can win on
coherence, confidence, privacy, and low cognitive load.

## Original product intent

A private message shared during this review captures the motivation behind
Saymark more clearly than a feature list:

- reject the inherited cat-themed Murmur identity;
- make transcription materially faster;
- improve the hotkey interface;
- support a start/stop shortcut so longer dictation does not require holding;
- put text into the active application instead of making an intermediate app UI
  the center of the workflow.

This is useful founder intent, not independent user research. It nevertheless
provides a strong decision filter: **Saymark is meant to remove the keyboard
without replacing it with another destination app.**

| Original intent | Current state | Remaining gap |
| --- | --- | --- |
| Remove the cat-themed identity | Product name, native visual direction, app icon, menu-bar mark, onboarding mark, and social preview have changed | Compiled and release-artifact validation remains |
| Make it faster | Local final and live-preview pipelines have measured performance gates | Public-device proof and speech-to-visible-text/revision measurements remain |
| Improve hotkey UI | Current working tree uses native segmented controls and a shortcut recorder | Popover still exposes three control concepts at once |
| Add start/stop hotkey | Toggle mode and a clickable HUD Stop action are implemented | Make the choice clearer in Settings and test long-session behavior |
| Write into the active app | Final text is atomically pasted into the focused field with clipboard fallback | Live insertion and safe revision of Saymark-owned text are not implemented |

The product decision is now explicit: **live field insertion is the primary
experience.** Saymark should continuously write into the active application,
then revise the recent text it owns as the streaming model gains context. The
HUD becomes status and recovery UI, not the main transcript surface.

This should not mean replacing the entire growing document on every update. The
interaction needs two regions:

- a **committed prefix** that is stable and left untouched;
- a short **revisable tail** that Saymark may replace as recognition improves.

Pauses or sufficiently stable token boundaries should advance text from the
revisable tail into the committed prefix. The final accurate pass may settle the
remaining tail when dictation stops.

This introduces real engineering constraints—cursor movement, focus changes,
provisional-text replacement, undo grouping, and differences between native,
Electron, browser, and terminal fields. They are now core product requirements,
not reasons to avoid the interaction.

Automatic ASR revision should be distinguished from explicit spoken editing
commands. Correcting “their” to “there” as more context arrives belongs in the
first live-insertion release. Commands such as “scratch that” or “replace the
last sentence” are a later semantic editing layer.

## Saymark's current strengths

### 1. The core interaction is unusually clear

The product has one primary gesture: hold a global shortcut and speak. Today the
field receives the final result on release; live insertion can change the
feedback without adding another gesture. Toggle mode supports longer input
without displacing the central push-to-talk behavior.

This is easier to understand than Superwhisper's mode-and-model matrix and is a
valid product advantage, not merely a missing feature.

### 2. Local-first is an architectural truth

Saymark's privacy claim is supported by the implementation:

- Speech recognition runs locally.
- Audio and transcript text are excluded from diagnostics.
- Analytics is opt-in and unavailable in local builds without an explicit key.
- Accessibility failure falls back to the clipboard instead of losing text.
- Secure-input and paste failures receive specific recovery messages.

This is a stronger foundation than a generic “privacy-first” claim.

### 3. The two-tier transcript is a distinctive interaction

The engine publishes a live draft roughly every 160 ms, then uses a
high-accuracy final model when recording stops. The HUD currently distinguishes
draft and final states; this provides the recognition foundation for moving the
same lifecycle into the active field.

That is a meaningful product story: **your words appear where you are writing
and improve while you keep speaking**.

### 4. Onboarding covers the full activation path

The current five-position flow includes:

- a concise explanation of the job;
- microphone and Accessibility setup;
- shortcut and hold/toggle selection;
- transparent model size and download progress;
- an in-window first dictation using the chosen global shortcut;
- an inline success state.

The current working tree also uses native controls, system typography, direct
tool language, one task per screen, a standard 680 × 500 titled window, and the
production Saymark mark. This is at least as complete as the setup sequence
Superwhisper documents, and Saymark explains local processing more directly.
The remaining work is visual and accessibility validation across every state.

### 5. Product engineering can become marketing proof

The repository already defines latency, memory, CPU, and word-error acceptance
gates. The latest July 2026 accepted benchmark records a 0.39-second median
final pass for the Efficient profile on the test machine. Few small products
have this level of performance discipline.

The gap is that users cannot see or evaluate any of it.

## Product gaps

### P0 — Live insertion with bounded correction is not implemented

The streaming pipeline already emits changing draft text, but
`DictationController` sends those updates only to the HUD. `TextInjector`
supports one atomic final paste and does not track a target field, insertion
range, or revisable span.

This is now the defining product gap. Saymark should make the active application
the transcript surface and preserve enough ownership state to revise only what
Saymark inserted.

**Recommendation**

Build a dedicated live-insertion coordinator with these invariants:

- capture the focused application, focused accessibility element, selection,
  and insertion anchor when dictation begins;
- maintain a committed prefix and a bounded revisable tail;
- diff each new draft against the prior draft and replace the smallest owned
  suffix rather than repasting the whole utterance;
- prefer range-based Accessibility replacement where the target supports it;
- provide a carefully tested keyboard/paste fallback for apps that do not;
- group the dictation into a predictable undo operation where the target app
  permits it;
- detect focus, selection, cursor, or user-edit changes and stop revising rather
  than overwrite text Saymark no longer owns;
- preserve the transcript and expose recovery when secure input, target
  incompatibility, or replacement failure occurs;
- settle the remaining provisional tail with the accurate final result.

Long-form dictation also requires an engine-level stability policy. The current
two-tier session treats the entire live transcript as provisional until stop.
For a growing document, Saymark should expose stable-prefix boundaries or
incrementally refine pause-delimited segments so only the most recent phrase
remains mutable.

Ship compatibility in tiers:

1. Native `NSTextView` and standard AppKit/SwiftUI fields.
2. Common browser and Electron editors.
3. Terminal and specialist editors through an explicit fallback.

Instrument replacement latency, revision size, ownership-loss events, fallback
rate, final divergence, and per-application success without logging transcript
content.

### Human response budget for natural live writing

Naturalness depends on what the person sees, not just model real-time factor or
the duration of an inference call. Saymark should treat human response
thresholds as product acceptance criteria.

The original 480 ms audio feed created only about 2.1 update opportunities per
second. Batching alone added an average 240 ms wait and as much as 480 ms before
inference and field mutation. Those half-second bursts were likely to
feel like delayed captioning rather than writing.

Use this initial perception budget:

| Human-visible event | Target |
| --- | ---: |
| Hotkey to listening feedback | p50 ≤ 50 ms; p95 ≤ 100 ms |
| Audio/inference update opportunity | Every 100–160 ms |
| Decodable word end to visible word | p50 ≤ 250 ms; p95 ≤ 400 ms |
| New hypothesis to field revision | p50 ≤ 50 ms; p95 ≤ 100 ms |
| Longest visible freeze during continuous speech | ≤ 300 ms |
| Stop gesture to final settled text | p50 ≤ 300 ms; p95 ≤ 500 ms |

These are product targets, not universal psychophysical constants. Validate them
with controlled fixtures and user observation. The key subjective question is
whether words appear before the speaker checks whether Saymark is keeping up.

Apple's responsiveness guidance uses 100 ms as a rough upper bound for
instantaneous discrete feedback and notes that even 50 ms can be perceptible in
continuous interactions, especially when timing is inconsistent. Speech adds a
necessary acoustic-context delay, so smooth, predictable token emission matters
more than pretending every sound can produce immediate text.

The streaming model is configured around a 160 ms internal chunk. A 20-run
160/240/320/480 ms experiment selected a 160 ms microphone feed after it kept
up without backlog, quality regression, or memory growth. Continue to reject
future cadence changes that add excess power use or unstable
revisions.

Measure perception separately from compute:

- first detected speech to first visible token;
- token emission to completed field mutation;
- interval and jitter between visible changes;
- age and size of the revisable tail;
- stop to final settlement;
- number and depth of revoked words.

Use versioned, consented benchmark audio to measure word-aligned latency.
Production diagnostics can retain content-free timings and counts.

### P0 — No transcript recovery surface

Saymark places or copies the final transcript, but exposes no recent-result
history. A failed paste, accidental overwrite, or disappointing transcript
becomes a dead end.

Superwhisper's history is more than storage. It supports search, replay,
reprocessing, comparison between raw and AI output, diagnostics, deletion, and
issue reporting. Its new CLI and MCP build on the same durable history.

**Recommendation**

Ship a deliberately small, local-only **Recent dictations** surface:

- text only by default;
- last 10–25 results;
- copy and reinsert;
- clear all;
- retention control: Off, session only, 1 day, 7 days, or manual;
- no saved audio by default;
- prominent “Stored only on this Mac” explanation.

This closes the trust and recovery gap without turning Saymark into a content
management product.

### P0 — Supported language behavior is unclear

The HUD says “Auto,” the engine accepts a language parameter, and the quality
plan mentions English plus conditional Russian coverage. The product UI does
not let a user know what is actually supported, detected, or guaranteed.

Superwhisper makes “100+ languages,” automatic detection, and translation a
major acquisition promise.

**Recommendation**

Before expanding language support, make the truth explicit:

- name the currently supported production languages;
- distinguish “supported,” “experimental,” and “not tested”;
- replace the generic `AUTO` badge if only one language is production-ready;
- add language choice only when it changes a real model behavior;
- publish a per-language quality matrix.

Ambiguity is more damaging than a narrow, honest language claim.

### P0 — The release product lacks public proof and a completed distribution

The repository now contains a protected tag-driven release workflow, Developer
ID signing and notarization checks, packaging, checksums, and a release
checklist. The README still correctly says no signed or notarized release has
been distributed yet. There is also no public product site in the repository,
pricing story, download funnel, testimonial set, or visible product demo.

Superwhisper offers a free tier, cross-platform licensing, a browser demo,
customer proof, detailed documentation, active product news, and a formal Trust
Center.

**Recommendation**

Finish and exercise the release proof stack before adding broad features:

1. Run the protected workflow and verify the first signed/notarized download on
   a clean account.
2. One excellent landing page.
3. A 20–30 second unedited cursor-to-text demo.
4. A plain-language privacy page.
5. A published performance methodology and device matrix.
6. A clear support and update path.
7. A simple price and trial model.

### P1 — No vocabulary, replacements, or user correction loop

Proper nouns, product names, acronyms, and recurring substitutions are a daily
accuracy problem. Superwhisper exposes custom vocabulary, text replacements,
snippets, and now CLI management of those assets.

**Recommendation**

Add a local **Words & replacements** feature before adding general AI modes:

- vocabulary terms with optional pronunciation hints;
- deterministic “heard → write” replacements;
- import/export as a small human-readable file;
- suggest additions from explicit user corrections only;
- never silently learn from transcript content.

This improves the core job while remaining legible and private.

### P1 — Model choices are described from the implementation outward

“Efficient” and “Live Preview” are better than raw model names, but the menu
label “Model” and the description “one efficient model” still emphasize
machinery rather than outcomes. Live Preview also requires an additional
download, yet the ongoing cost and behavior are not summarized in the popover.

**Recommendation**

Make live insertion the normal experience rather than an optional preview mode.
If a user-facing control remains, describe delivery behavior:

- **Write as I speak** — text appears at the cursor and recent words may improve.
- **Insert when finished** — compatibility fallback; one final insertion.

Choose the recognition plan automatically where possible. Show storage, memory,
and compatibility implications in Settings, not the primary popover.

### P1 — Input-device feedback is decorative

The menu's microphone meter is explicitly animated rather than connected to
live input level. Superwhisper includes input-device selection and microphone
configuration in setup.

**Recommendation**

- Replace the decorative meter with actual input level.
- Add microphone selection when more than one device is available.
- Detect “permission granted but no usable signal.”
- Let the onboarding try-it step double as a real microphone test.

### P1 — No explicit update, version, or support surface

The menu exposes Settings, setup tour, and Quit. It does not expose version,
check-for-updates, release notes, support, or report-a-problem actions.

**Recommendation**

Add a compact About/Support destination containing version, update status,
privacy, diagnostics export, and issue reporting. Keep diagnostics technical
controls out of the main Settings form unless an advanced section is opened.

### P2 — No transformation layer

Superwhisper's largest functional advantage is its optional second step: a
language model can clean, format, translate, or reshape the transcript using
application context and custom instructions.

This is strategically important but should not be Saymark's first response.
Adding generic modes now would weaken the “dependable local writing layer”
position and introduce latency, privacy explanation, model choice, prompt
debugging, and failure-mode complexity.

**Recommendation**

Sequence this as a later, constrained capability:

1. deterministic cleanup rules;
2. optional local “polish” with before/after preview;
3. a few outcome-led recipes such as Message, Email, and Note;
4. custom instructions only after history, recovery, and transparency exist.

Never make AI rewriting implicit in the default transcription path.

### P2 — Files, meetings, and speaker separation

Superwhisper supports audio/video files, system audio, long-form meetings,
speaker separation, and meeting notes.

These are adjacent jobs with different interaction, retention, and support
requirements. They would move Saymark away from its current insertion-point
focus.

**Recommendation**

Defer until the system-wide dictation experience has retention, vocabulary,
language clarity, distribution, and user proof. If demand is strong, begin with
Finder “Open With Saymark” file transcription rather than a meeting bot.

### P3 — Platform and agent ecosystem

Superwhisper now spans desktop and mobile and exposes history through a CLI and
MCP server. This creates both device continuity and an automation moat.

Saymark's native Mac-only stance is currently an advantage because it makes the
promise believable. Do not dilute it prematurely.

Revisit export, CLI, or agent integration only after Saymark has a user-owned
local history format worth integrating with.

## Brand and design gaps

### B0 — The defined identity is implemented

The app now includes a complete macOS app-icon asset set, an optically tuned
small-size icon, a monochrome `SaymarkMenuBar` template used by the live menu,
reproducible vector masters, and a Saymark-owned social preview. Onboarding uses
the production mark. The compact HUD and popover intentionally retain semantic
system symbols where they communicate state more clearly than a scaled logo.

**Recommendation**

Validate the compiled asset catalog and every macOS icon size in the release
build. Add website favicon and high-contrast variants when the website work
begins.

Test the wave-to-caret silhouette without glow. At small sizes, it should read as
one transformation, not a waveform next to a pause symbol.

### B0 — Legacy Murmur product branding is removed

The repository social preview, app icon, menu-bar icon, onboarding, HUD, and
popover now use the Saymark identity and neutral native palette. Murmur remains
only where attribution, historical security context, or migration documentation
requires it.

**Recommendation**

Keep origin credit in the README and legal material, and include the brand audit
in release validation so product identity does not regress.

### B0 — The palette migration is substantially complete

The brand direction specifies graphite, mist, silver, and Signal Blue and
explicitly rejects orange, yellow, and brown. The current working tree uses
native window and control surfaces, semantic label/separator colors, and a
restrained blue accent across the menu and onboarding. The prior brown-toned
onboarding stage and controls are gone.

**Recommendation**

Consolidate the remaining helpers into one semantic token layer used by
onboarding, HUD, popover, and Settings:

- surface;
- elevated surface;
- primary and secondary text;
- divider;
- active;
- success;
- warning;
- destructive;
- draft transcript;
- confirmed transcript.

Keep native materials as the default and delete helpers that no longer provide
meaning beyond system semantic colors.

### B1 — Typography is now coherent

The current onboarding rewrite removes the serif display titles and uses system
sans-serif styles throughout. It now matches the quiet, native,
instrument-like direction of the popover and Settings.

**Recommendation**

Preserve this hierarchy. Let the production mark and live/final transcript
behavior provide distinctiveness instead of introducing a separate editorial
type voice.

### B1 — The onboarding narrator gap is resolved in the working tree

The narrator rail, speech bubble, typewriter task, character animation, and
first-person assistant copy have been removed. The new copy is direct and
non-anthropomorphic, matching “human, not anthropomorphic.”

**Recommendation**

Treat this as a guardrail: do not reintroduce mascot behavior as the brand mark
develops. Reserve motion for real recording, processing, download, and success
state.

### B1 — The main surfaces carry too many competing mental models

The popover asks users to understand Model, Insert, and Hotkey as three segmented
controls. Settings separately exposes shortcut, insertion, privacy, and detailed
logging. HUD-only mode is described as both an insertion destination and a
presentation feature.

**Recommendation**

Clarify the information architecture:

- Popover: status, start/stop, current experience, recent dictation, Settings.
- Settings / Dictation: shortcut, hold/toggle, and live-insertion fallback.
- Settings / Output: type at cursor or copy only.
- Settings / Presentation: a separate subtitle mode, if it remains a supported
  job.
- Settings / Privacy: retention and analytics.
- Settings / Advanced: diagnostics and model storage.

### B1 — The product needs visible state confidence

The HUD handles listening, processing, final, and error states, but the product
story does not yet emphasize the transition enough. Superwhisper's visual system
is memorable because its amorphous triangular mark and dark field are repeated
everywhere.

**Recommendation**

Make the wave-to-caret behavior Saymark's repeated signature:

- waveform motion resolves into a stable caret as recent text is committed;
- provisional text is visibly marked only where the target app safely supports
  styling; otherwise the bounded revisable tail provides the behavior without
  visual decoration;
- the HUD confirms listening, ownership loss, fallback, and final settlement
  without duplicating the transcript;
- failures stop revision immediately and expose the recovery action.

This turns a product truth into a brand behavior.

### B2 — No marketing design system exists yet

The brand direction describes a website, but no current Saymark site or release
marketing system appears in the repository.

**Recommendation**

Build the first site around evidence, not a feature grid:

1. **Hero:** “Speak naturally. Write anywhere.”
2. **Live proof:** unedited cursor-to-text demonstration.
3. **Three reasons:** private, fast, dependable.
4. **How it feels:** hold, speak, and watch words appear where you are writing.
5. **Measured proof:** latency, offline behavior, supported Macs/languages.
6. **Privacy:** what stays local and what is optional.
7. **Download and price.**

Avoid Superwhisper's black fashion-tech styling and multicolor feature accents.
Saymark should feel like a first-party Mac utility: light-aware, precise, calm,
and transparent.

## Positioning recommendation

### Category

Native voice writing for Mac

### Audience

Mac users who write throughout the day and value speed, privacy, and a low
maintenance tool more than AI workflow customization.

### Position

> For Mac users who want to write at the speed of speech, Saymark is the private
> voice-writing layer that writes directly at the cursor and corrects its recent
> words as you continue speaking. Unlike configurable AI dictation platforms,
> Saymark runs locally and makes the important choices for you.

### Message hierarchy

1. **Speak naturally. Write anywhere.**
2. See words appear in the active app while you speak; recent text improves as
   Saymark gains context.
3. Runs on your Mac. Audio and transcripts do not need to leave it.
4. One shortcut; no prompts, provider setup, or model graph to manage.
5. A quiet status HUD that stays out of the writing surface.

Do not lead with “AI,” model names, open source, or a feature count. They are
supporting facts, not the user outcome.

## Recommended roadmap

### Now — release coherence

- Live insertion coordinator with target/range ownership and bounded revision.
- Stable-prefix/revisable-tail policy for long dictation.
- Human-perception acceptance gates and 160/240/320 ms feed benchmarks.
- Compatibility tests across native, browser, Electron, and terminal targets.
- Atomic final insertion retained as a safe fallback.
- Keep brand-regression checks in compiled and release-artifact validation.
- Validate the native onboarding at final window size and standard chrome,
  including dark mode, VoiceOver, keyboard navigation, and larger text.
- Exercise the signed/notarized release workflow and add an update mechanism.
- Plain supported-language statement.
- Real microphone meter and device check.
- Quiet status HUD; the active field is the primary transcript surface.
- Landing page, demo, privacy page, and pricing.

### Next — confidence and personalization

- Local recent-dictation recovery.
- Retention controls.
- Vocabulary and deterministic replacements.
- About/support/diagnostics export.
- Published device and accuracy benchmarks.

### Later — carefully expand the job

- Optional local polish.
- Small set of outcome-led writing recipes.
- File transcription.
- Exportable local history and CLI.
- Additional platforms only when continuity outweighs native focus.

## What not to copy from Superwhisper

- A large model picker in the primary experience.
- Automatic cloud processing hidden behind “smart” language.
- Many modes before users can inspect, recover, and compare results.
- A dark futuristic aesthetic that makes Saymark look like a follower.
- Meetings and speaker separation before everyday dictation is fully released.
- Platform breadth that weakens the native-Mac quality bar.

## Success measures

| Goal | Suggested measure |
| --- | --- |
| Activation | Permission completion, model-ready completion, and first successful insertion |
| Core reliability | Live-update success rate; ownership-loss rate; fallback rate; empty-result rate |
| Speed | p50/p95 speech-to-visible-text, revision, freeze, and final-settle budgets |
| Quality | Final correction rate; provisional-to-final divergence; vocabulary replacement usage |
| Trust | Local-history opt-in rate; retention choice; privacy-page comprehension |
| Habit | Active dictation days per week and dictations per active day |
| Recovery | Percentage of failed/overwritten results recovered from Recent dictations |

Do not use raw recording minutes as the primary north-star metric. The product
creates value when users successfully place usable text with less friction.

## Evidence and sources

### Saymark

- `README.md`
- `Branding/BRAND_DIRECTION.md`
- `Sources/Saymark/Onboarding/`
- `Sources/Saymark/MenuPopover.swift`
- `Sources/Saymark/HUDOverlay.swift`
- `Sources/Saymark/SettingsView.swift`
- `Sources/Saymark/Theme.swift`
- `Sources/Saymark/DictationController.swift`
- `SaymarkKit/Sources/SaymarkKit/DictationPlan.swift`
- `docs/privacy-and-security.md`
- `docs/performance-acceptance.md`
- `docs/benchmark-results.md`

### Human responsiveness

- [Apple: Understanding user interface responsiveness](https://developer.apple.com/documentation/xcode/understanding-user-interface-responsiveness)
- [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Dissecting User-Perceived Latency of On-Device End-to-End Speech Recognition](https://arxiv.org/abs/2104.02207)
- [Evaluating Automatic Speech Recognition in an Incremental Setting](https://arxiv.org/abs/2302.12049)

### Superwhisper

- [Product introduction](https://superwhisper.com/docs/get-started/introduction)
- [Modes](https://superwhisper.com/docs/modes/modes)
- [Super Mode and context awareness](https://superwhisper.com/docs/modes/super)
- [History](https://superwhisper.com/docs/get-started/interface-history)
- [File transcription](https://superwhisper.com/docs/get-started/transcribe-files)
- [Voice models](https://superwhisper.com/docs/models/voice)
- [Models and privacy](https://superwhisper.com/models)
- [Pro plans](https://superwhisper.com/docs/get-started/sw-pro)
- [Sensitive data guidance](https://superwhisper.com/docs/security/sensitive-data)
- [Trust Center](https://trust.superwhisper.com/)
- [CLI and MCP announcement](https://superwhisper.com/blog/cli-mcp)

Superwhisper's product and pricing are fast-moving. Recheck current claims before
using this comparison in external marketing.
