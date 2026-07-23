#!/bin/zsh
set -euo pipefail

source_app="${1:?usage: install-local.sh /path/to/Saymark.app}"
destination="/Applications/Saymark.app"

# Use only Saymark's isolated local keychain. Never auto-select identities from
# the login keychain, where a revoked Apple Development certificate may appear.
identity="${SAYMARK_LOCAL_SIGN_IDENTITY:-Saymark Local Development}"
keychain="${SAYMARK_LOCAL_SIGN_KEYCHAIN:-$HOME/Library/Keychains/saymark-local-signing.keychain-db}"
source "${0:A:h}/local-signing-password.sh"
keychain_password="$(saymark_local_signing_password "$keychain")"
security unlock-keychain -p "$keychain_password" "$keychain"
fingerprint="$(security find-identity -v -p codesigning "$keychain" | awk -v name="\"$identity\"" 'index($0, name) { print $2; exit }')"
if [[ -z "$fingerprint" ]]; then
  print -u2 "No usable $identity identity in $keychain"
  exit 1
fi
codesign --force --deep --sign "$fingerprint" --keychain "$keychain" --timestamp=none "$source_app"
codesign --verify --deep --strict "$source_app"

if [[ -d "$destination" ]]; then
  # Address the local bundle id specifically; never stop the official Saymark app.
  osascript -e 'tell application id "com.eloe.saymark.local" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -f '^/Applications/Saymark.app/Contents/MacOS/Saymark$' >/dev/null || break
    sleep 0.1
  done
  pkill -TERM -f '^/Applications/Saymark.app/Contents/MacOS/Saymark$' 2>/dev/null || true
  timestamp="$(date +%Y%m%d-%H%M%S)"
  mv "$destination" "/Applications/Saymark.app.backup-$timestamp"
fi
ditto "$source_app" "$destination"
codesign --verify --deep --strict "$destination"
open "$destination"

print "Installed stable-signed Saymark: $destination"
codesign -d -r- "$destination" 2>&1
