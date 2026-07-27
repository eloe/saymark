#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
classifier="$repo_root/Scripts/codeql-path-is-relevant.sh"

relevant_paths=(
  "Sources/Saymark/AppDelegate.swift"
  "Sources/Saymark/Onboarding/OnboardingModel.swift"
  "SaymarkKit/Sources/SaymarkKit/DictationSession.swift"
  "Project.swift"
  "Apps/MenuBar/Project.swift"
  "Workspace.swift"
  "Workspaces/Release/Workspace.swift"
  "Package.swift"
  "SaymarkKit/Package.swift"
  "Package.resolved"
  "SaymarkKit/Package.resolved"
  ".package.resolved"
  "Saymark.entitlements"
  "Saymark.xcodeproj/project.pbxproj"
  "Config/Release.plist"
  "Config/Base.xcconfig"
  "Saymark.xcodeproj/xcshareddata/xcschemes/Saymark.xcscheme"
  ".github/workflows/codeql.yml"
  ".github/codeql/codeql-config.yml"
  ".mise.toml"
  "Scripts/check-xcode-version.sh"
  "Scripts/codeql-path-is-relevant.sh"
)

irrelevant_paths=(
  "Tests/SaymarkTests/DictationControllerTests.swift"
  "Tests/SaymarkUITests/OnboardingUITests.swift"
  "SaymarkKit/Tests/SaymarkKitTests/DictationSessionTests.swift"
  "README.md"
  "docs/security-and-secrets.md"
  "Makefile"
  ".github/workflows/quality.yml"
  "Scripts/check-ci-config.sh"
  "Sources/Saymark/Resources/Localizable.xcstrings"
  "Branding/Production/SaymarkAppIcon.svg"
)

failures=0

for path in "${relevant_paths[@]}"; do
  if ! "$classifier" "$path"; then
    echo "codeql-classifier: expected relevant: $path" >&2
    ((failures += 1))
  fi
done

for path in "${irrelevant_paths[@]}"; do
  if "$classifier" "$path"; then
    echo "codeql-classifier: expected irrelevant: $path" >&2
    ((failures += 1))
  fi
done

if ((failures > 0)); then
  echo "codeql-classifier: FAIL ($failures classification errors)" >&2
  exit 1
fi

printf 'codeql-classifier: PASS (%d relevant, %d irrelevant cases)\n' \
  "${#relevant_paths[@]}" "${#irrelevant_paths[@]}"
