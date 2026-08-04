#!/usr/bin/env bash
set -euo pipefail

build_only=false
if [[ ${1:-} == --build-only ]]; then
  build_only=true
  shift
  if (($# > 0)); then
    echo "target-matrix: ERROR — --build-only accepts no additional options" >&2
    exit 64
  fi
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
revision=$(git -C "$repo_root" rev-parse HEAD)
output_root="$repo_root/.build/atomic-insertion-evidence"
binary="$output_root/AtomicInsertionTargetHarness"
build_key_file="$output_root/build-key"
build_metadata_file="$output_root/build-metadata"
sources=(
  "$repo_root/SaymarkKit/Sources/SaymarkKit/Accessibility.swift"
  "$repo_root/SaymarkKit/Sources/SaymarkKit/TextInjector.swift"
  "$repo_root/Evidence/AtomicInsertionTargetHarness.swift"
)
tracked_sources=(
  "SaymarkKit/Sources/SaymarkKit/Accessibility.swift"
  "SaymarkKit/Sources/SaymarkKit/TextInjector.swift"
  "Evidence/AtomicInsertionTargetHarness.swift"
  "Scripts/run-atomic-insertion-target-evidence.sh"
)

for source in "${tracked_sources[@]}"; do
  git -C "$repo_root" cat-file -e "$revision:$source" 2>/dev/null || {
    echo "target-matrix: BLOCKED — evidence source is absent from $revision: $source" >&2
    exit 2
  }
done
if ! git -C "$repo_root" diff --quiet "$revision" -- "${tracked_sources[@]}"; then
  echo "target-matrix: BLOCKED — evidence sources must exactly match $revision" >&2
  exit 2
fi

mkdir -p "$output_root"
swiftc_path=$(/usr/bin/xcrun --find swiftc)
swiftc_version=$("$swiftc_path" --version | tr '\n' ';')
sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
sdk_version=$(/usr/bin/xcrun --sdk macosx --show-sdk-version)
xcode_version=$(/usr/bin/xcodebuild -version | tr '\n' ';')
compile_contract='explicit-macos-sdk;swift-version=5;frameworks=AppKit,ApplicationServices,Carbon,CoreGraphics,Foundation'
build_key=$(
  {
    for source in "${tracked_sources[@]}"; do
      git -C "$repo_root" rev-parse "$revision:$source"
    done
    printf '%s\n' "$swiftc_path" "$swiftc_version" "$sdk_path" "$sdk_version" "$xcode_version"
    printf '%s\n' "$compile_contract"
  } | shasum -a 256 | awk '{print $1}'
)
recorded_build_key=''
if [[ -f $build_key_file ]]; then
  recorded_build_key=$(<"$build_key_file")
fi
needs_build=$([[ -x $binary && -f $build_metadata_file && $recorded_build_key == "$build_key" ]] && printf false || printf true)
if [[ $needs_build == true ]]; then
  source_stage="$output_root/sources-$build_key"
  mkdir -p "$source_stage"
  staged_sources=()
  for source in "${sources[@]}"; do
    relative_source=${source#"$repo_root/"}
    staged_source="$source_stage/$(basename "$relative_source")"
    git -C "$repo_root" show "$revision:$relative_source" > "$staged_source"
    staged_sources+=("$staged_source")
  done
  "$swiftc_path" -sdk "$sdk_path" -parse-as-library -swift-version 5 \
    "${staged_sources[@]}" \
    -o "$binary" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -framework CoreGraphics \
    -framework Foundation
  signature=$(/usr/bin/codesign -dvvv "$binary" 2>&1)
  grep -q '^Signature=adhoc$' <<<"$signature" || {
    echo "target-matrix: BLOCKED — evidence harness is not ad-hoc signed" >&2
    exit 2
  }
  grep -q '^TeamIdentifier=not set$' <<<"$signature" || {
    echo "target-matrix: BLOCKED — evidence harness unexpectedly has a Team Identifier" >&2
    exit 2
  }
  cdhash=$(awk -F= '/^CDHash=/ { print $2; exit }' <<<"$signature")
  binary_sha256=$(shasum -a 256 "$binary" | awk '{print $1}')
  printf '%s\n' "$build_key" > "$build_key_file"
  {
    printf 'build.compiler_path=%s\n' "$swiftc_path"
    printf 'build.compiler_version=%s\n' "$swiftc_version"
    printf 'build.sdk_path=%s\n' "$sdk_path"
    printf 'build.sdk_version=%s\n' "$sdk_version"
    printf 'build.xcode=%s\n' "$xcode_version"
    printf 'build.contract=%s\n' "$compile_contract"
    printf 'build.key=%s\n' "$build_key"
    printf 'build.signature=adhoc\n'
    printf 'build.team_identifier=none\n'
    printf 'build.cdhash=%s\n' "$cdhash"
    printf 'build.sha256=%s\n' "$binary_sha256"
  } > "$build_metadata_file"
fi

if ! /usr/bin/codesign --verify --strict "$binary"; then
  echo "target-matrix: BLOCKED — cached evidence harness signature is invalid" >&2
  exit 2
fi
current_signature=$(/usr/bin/codesign -dvvv "$binary" 2>&1)
grep -q '^Signature=adhoc$' <<<"$current_signature" || {
  echo "target-matrix: BLOCKED — cached evidence harness is not ad-hoc signed" >&2
  exit 2
}
grep -q '^TeamIdentifier=not set$' <<<"$current_signature" || {
  echo "target-matrix: BLOCKED — cached evidence harness unexpectedly has a Team Identifier" >&2
  exit 2
}
current_cdhash=$(awk -F= '/^CDHash=/ { print $2; exit }' <<<"$current_signature")
current_sha256=$(shasum -a 256 "$binary" | awk '{print $1}')
recorded_cdhash=$(awk -F= '$1 == "build.cdhash" { print $2; exit }' "$build_metadata_file")
recorded_sha256=$(awk -F= '$1 == "build.sha256" { print $2; exit }' "$build_metadata_file")
if [[ -z $recorded_cdhash || $current_cdhash != "$recorded_cdhash" ||
      -z $recorded_sha256 || $current_sha256 != "$recorded_sha256" ]]; then
  echo "target-matrix: BLOCKED — cached evidence harness does not match persisted build metadata" >&2
  exit 2
fi

while IFS= read -r metadata; do
  printf '%s\n' "$metadata"
done < "$build_metadata_file"
if [[ $build_only == true ]]; then
  printf 'target-matrix: READY — committed evidence harness built without requesting Accessibility\n'
  exit 0
fi
exec "$binary" --revision "$revision" "$@"
