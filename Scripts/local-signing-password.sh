#!/bin/zsh

# Shared by setup-local-signing.sh and install-local.sh. The random password for
# Saymark's isolated development keychain is itself stored in the user's login
# Keychain, never in this repository or a plaintext file.

saymark_local_signing_password() {
  local keychain="${1:?keychain path required}"
  local allow_create="${2:-0}"
  local account
  account="$(id -un)"
  local service="com.eloe.saymark.local-signing.keychain-password"
  local login_keychain="$HOME/Library/Keychains/login.keychain-db"
  local stored=""

  stored="$(security find-generic-password \
    -a "$account" -s "$service" -w "$login_keychain" 2>/dev/null || true)"

  if [[ -f "$keychain" ]]; then
    if [[ -n "$stored" ]] && security unlock-keychain -p "$stored" "$keychain" 2>/dev/null; then
      print -r -- "$stored"
      return 0
    fi

    # One-time migration from the original empty-password local keychain.
    if [[ -z "$stored" ]] && security unlock-keychain -p "" "$keychain" 2>/dev/null; then
      local migrated
      migrated="$(openssl rand -hex 32)"
      security set-keychain-password -o "" -p "$migrated" "$keychain"
      security add-generic-password -U \
        -a "$account" -s "$service" -w "$migrated" "$login_keychain" >/dev/null
      print -u2 "Migrated Saymark's local signing keychain to a protected password."
      print -r -- "$migrated"
      return 0
    fi

    print -u2 "Cannot unlock the Saymark local signing keychain."
    print -u2 "Remove it deliberately and run make setup-local-signing to create a new identity."
    return 1
  fi

  if [[ "$allow_create" != "1" ]]; then
    print -u2 "Saymark's local signing keychain does not exist. Run make setup-local-signing."
    return 1
  fi

  if [[ -z "$stored" ]]; then
    stored="$(openssl rand -hex 32)"
    security add-generic-password -U \
      -a "$account" -s "$service" -w "$stored" "$login_keychain" >/dev/null
  fi
  print -r -- "$stored"
}
