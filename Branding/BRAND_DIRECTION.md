# Saymark brand direction

## Brand idea

**Speech, made useful.**

Saymark turns natural speech into dependable writing wherever the cursor is. The brand should feel like a quiet part of macOS: immediate, precise, private, and trustworthy—not like an AI character or a recording studio.

## Positioning

Saymark is the native voice-writing layer for Mac. It earns preference through speed, excellent final text, local-first privacy, and interfaces that stay out of the way.

### Product promise

Speak naturally. Write anywhere.

### Brand attributes

- Native, not themed
- Precise, not clinical
- Quiet, not invisible
- Capable, not complicated
- Human, not anthropomorphic

## Visual system

### Palette

Use semantic macOS colors in the product wherever possible. These fixed values are for marketing and controlled brand surfaces.

| Role | Name | Value | Use |
| --- | --- | --- | --- |
| Primary dark | Graphite 950 | `#111317` | Icon ground, dark brand fields |
| Elevated dark | Graphite 800 | `#252A31` | Panels and secondary surfaces |
| Primary light | Mist 50 | `#F5F7FA` | Light brand fields |
| Secondary | Silver 300 | `#B9C0CA` | Rules, hardware-like details |
| Accent | Signal Blue | `#3A9EFF` | Active listening, selection, progress |
| Accent quiet | Air Blue | `#88C8FF` | Subtle highlights and inactive traces |
| Success | System green | semantic | Completion only, never decoration |
| Failure | System red | semantic | Errors only, never decoration |

Do not introduce orange, yellow, brown, rainbow gradients, or a second decorative accent. Blue indicates live activity; neutral materials indicate readiness.

### Materials

- Use native vibrancy and material APIs in the app rather than painted fake glass.
- Prefer graphite, smoked glass, satin aluminum, and subtle inner highlights.
- Keep depth shallow. Avoid oversized shadows, decorative glowing borders, and
  glossy toy-like controls. The restrained Start/Stop perimeter halo is a
  functional listening state, not surface decoration.
- Let macOS appearance, contrast, and accessibility settings govern final rendering.

### Typography

- Product UI: system San Francisco through native text styles.
- Marketing display: SF Pro Display where licensing and platform permit; otherwise a neutral grotesk with similar proportions.
- Data and benchmark labels: SF Mono sparingly.
- Use sentence case. Avoid all caps except tiny technical labels.

### Motion

Motion explains state rather than adding personality.

- Hold and Start/Stop listening: immediate HUD appearance and gentle amplitude
  response.
- Start/Stop listening: one short blue perimeter bloom on the active display,
  then a faint steady edge. Never pulse continuously.
- Start/Stop success: a brief green perimeter fade, never a persistent
  decorative glow.
- Processing: continuous restrained movement, never an indeterminate flashing panel.
- Inserting: caret-directed completion movement, then a short readable dwell.
- Reduced Motion: crossfades and value changes only.

## Icon language

The core metaphor is **voice becoming a mark at the insertion point**. A waveform alone means audio; a microphone means recording. Saymark should own the transition from sound to written text.

### Recommended direction: wave to caret

Concept 01 is the strongest foundation. A fluid sound stroke resolves into a crisp insertion caret. It is immediate, distinctive, and describes the product without a literal microphone.

Before production:

- Reduce the stroke to one or two bends.
- Match optical weight between the wave and caret.
- Remove excess glow and exterior rim detail.
- Test monochrome and template-rendered variants at 16, 18, 22, and 32 points.
- Redraw as geometry; do not ship the generated raster as the final master.

### Supporting explorations

- Concept 02, voice mark: distinctive and compact, but currently reads as arrows or a pen nib. Retain only as shape research.
- Concept 03, ripple caret: clearly signals listening, but is busier and can resemble broadcast or connectivity symbols. It is not recommended as the primary mark.

## Voice and language

Saymark speaks plainly and briefly.

Preferred:

- “Listening”
- “Finishing your text”
- “Inserted”
- “Copied—paste anywhere”
- “Saymark needs Accessibility access to type for you.”

Avoid:

- Cute animal language or mascots
- Claims that every result is “magical”
- Technical model names in normal user flows
- Blaming the user when permissions or insertion fail
- Generic “Something went wrong” when a recovery is known

## Initial applications

- Menu bar: monochrome wave-to-caret template mark.
- HUD: system material, strong state label, blue reserved for live audio/progress.
- App icon: graphite tile with the wave-to-caret mark.
- Settings: standard macOS sidebar and form controls; brand color only for selection and status.
- Website: generous neutral space, native-window product imagery, restrained blue trace connecting speech to text.
