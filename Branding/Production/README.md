# Production brand assets

These SVGs are the editable masters for Saymark's selected **wave-to-caret**
identity. They are deterministic geometry rather than generated raster art.

- `SaymarkAppIcon.svg` — 1024-point macOS app-icon master
- `SaymarkAppIconSmall.svg` — optically simplified non-Retina 16-pixel master
- `SaymarkMenuBar.svg` — monochrome 18-point menu-bar template master
- `SaymarkSocialPreview.svg` — 1280 × 640 GitHub social-preview master

Run `Scripts/generate-brand-assets.sh` after editing a master. It renders the
complete macOS AppIcon set and GitHub preview. The menu-bar master is kept in
sync with the asset-catalog copy by the same script.

Keep the mark original and neutral: no cat/mascot, microphone, warm palette,
purple gradient, or competitor artwork. An App Store similarity review is
still required before public distribution.
