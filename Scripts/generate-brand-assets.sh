#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
masters="$repo_root/Branding/Production"
catalog="$repo_root/Sources/Saymark/Resources/Media.xcassets"
app_icons="$catalog/AppIcon.appiconset"
menu_icon="$catalog/SaymarkMenuBar.imageset/SaymarkMenuBar.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required (install librsvg with Homebrew)." >&2
  exit 1
fi

mkdir -p "$app_icons" "$(dirname "$menu_icon")"

while read -r name pixels; do
  rsvg-convert -w "$pixels" -h "$pixels" \
    "$masters/SaymarkAppIcon.svg" \
    -o "$app_icons/AppIcon-$name.png"
done <<'SIZES'
16 16
16@2x 32
32 32
32@2x 64
128 128
128@2x 256
256 256
256@2x 512
512 512
512@2x 1024
SIZES

# The 16 px 1x slot needs heavier, simpler geometry to preserve the caret.
rsvg-convert -w 16 -h 16 \
  "$masters/SaymarkAppIconSmall.svg" \
  -o "$app_icons/AppIcon-16.png"

ditto "$masters/SaymarkMenuBar.svg" "$menu_icon"
rsvg-convert -w 1280 -h 640 \
  "$masters/SaymarkSocialPreview.svg" \
  -o "$repo_root/.github/social-preview.png"

echo "Generated Saymark app, menu-bar, and social assets."
