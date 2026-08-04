#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
resolved="$repo_root/.package.resolved"
vendor_metadata="$repo_root/Vendor/KeyboardShortcuts/UPSTREAM.json"
output="$repo_root/ThirdPartyLicenses"

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [SourcePackages/checkouts]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  checkouts=$1
else
  checkouts=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -type d -path '*/SourcePackages/checkouts' -print 2>/dev/null \
    | while IFS= read -r candidate; do
        [[ -d "$candidate/mlx-audio-swift" ]] || continue
        revision=$(git -C "$candidate/mlx-audio-swift" rev-parse HEAD 2>/dev/null || true)
        expected=$(awk '
          /"identity" : "mlx-audio-swift"/ { found=1 }
          found && /"revision"/ { gsub(/[",]/, "", $3); print $3; exit }
        ' "$resolved")
        [[ "$revision" == "$expected" ]] && echo "$candidate" && break
      done)
fi

[[ -n "${checkouts:-}" && -d "$checkouts" ]] || {
  echo "Could not find package checkouts matching .package.resolved." >&2
  echo "Resolve packages first or pass the SourcePackages/checkouts path." >&2
  exit 1
}

staging=$(mktemp -d -t saymark-licenses)
trap 'rm -rf "$staging"' EXIT

awk '
  /"identity"/ {
    identity=$3
    gsub(/[",]/, "", identity)
  }
  /"revision"/ {
    revision=$3
    gsub(/[",]/, "", revision)
    if (identity != "") print identity "\t" revision
    identity=""
  }
' "$resolved" | while IFS=$'\t' read -r identity revision; do
  checkout=$(find "$checkouts" -mindepth 1 -maxdepth 1 -type d \
    -iname "$identity" -print -quit)
  [[ -n "$checkout" ]] || {
    echo "Missing checkout for $identity" >&2
    exit 1
  }

  actual=$(git -C "$checkout" rev-parse HEAD)
  [[ "$actual" == "$revision" ]] || {
    echo "$identity checkout is $actual; expected $revision" >&2
    exit 1
  }

  found=0
  while IFS= read -r source; do
    relative=${source#"$checkout"/}
    filename=${relative//\//--}
    filename=${filename// /_}
    cp "$source" "$staging/${identity}--${filename}"
    found=1
  done < <(find "$checkout" -maxdepth 6 -type f \( \
      -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'LICENSE-*' -o \
      -iname 'COPYING' -o -iname 'COPYING.*' -o \
      -iname 'NOTICE' -o -iname 'NOTICE.*' \
    \) -print | sort)

  if [[ "$found" -eq 0 ]]; then
    override="$repo_root/LegalLicenseOverrides/${identity}-LICENSE.txt"
    [[ -f "$override" ]] || {
      echo "$identity has no license file at pinned revision $revision" >&2
      exit 1
    }
    cp "$override" "$staging/${identity}--LICENSE.txt"
  fi
done

vendor_name=$(node -e 'const metadata = require(process.argv[1]); console.log(metadata.name.toLowerCase())' \
  "$vendor_metadata")
vendor_path=$(node -e 'const metadata = require(process.argv[1]); console.log(metadata.localPath)' \
  "$vendor_metadata")
vendor_license="$repo_root/$vendor_path/license"
[[ -f "$vendor_license" ]] || {
  echo "$vendor_name vendored package is missing its license" >&2
  exit 1
}
cp "$vendor_license" "$staging/${vendor_name}--license"

unicode_license="$output/unicode-15.1.0-LICENSE.txt"
[[ -f "$unicode_license" ]] || {
  echo "Unicode 15.1 data license is missing" >&2
  exit 1
}
cp "$unicode_license" "$staging/unicode-15.1.0-LICENSE.txt"

rm -rf "$output"
mv "$staging" "$output"
trap - EXIT
"$repo_root/Scripts/check-legal-notices.sh"
