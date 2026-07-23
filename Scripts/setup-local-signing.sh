#!/bin/zsh
set -euo pipefail

identity="Saymark Local Development"
keychain="$HOME/Library/Keychains/saymark-local-signing.keychain-db"

ensure_search_list() {
  if ! security list-keychains -d user | grep -Fq "\"$keychain\""; then
    local existing
    existing=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')}")
    security list-keychains -d user -s "${existing[@]}" "$keychain"
  fi
}

if [[ -f "$keychain" ]]; then
    security unlock-keychain -p "" "$keychain"
  ensure_search_list
  if security find-identity -v -p codesigning "$keychain" | grep -Fq "\"$identity\""; then
    print "Local signing identity is ready: $identity"
    exit 0
  fi
  print -u2 "The Saymark local keychain exists but has no usable signing identity: $keychain"
  exit 1
fi

work="$(mktemp -d /tmp/saymark-local-signing.XXXXXX)"
trap 'rm -rf "$work"' EXIT
password="$(openssl rand -hex 24)"

openssl req -new -newkey rsa:3072 -x509 -sha256 -days 3650 -nodes \
  -subj "/CN=$identity/O=Saymark Local Development" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "subjectKeyIdentifier=hash" \
  -keyout "$work/private-key.pem" -out "$work/certificate.pem" >/dev/null 2>&1

openssl pkcs12 -export -legacy -name "$identity" \
  -inkey "$work/private-key.pem" -in "$work/certificate.pem" \
  -passout "pass:$password" -out "$work/identity.p12"

# This isolated keychain contains only the non-distribution Saymark Local key.
# Its empty password allows repeatable local builds without storing a credential.
security create-keychain -p "" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "" "$keychain"
ensure_search_list
security import "$work/identity.p12" -k "$keychain" -f pkcs12 \
  -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$keychain" >/dev/null

# User-domain trust only. This identity cannot produce an official/notarized app.
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$work/certificate.pem"

security find-identity -v -p codesigning "$keychain" | grep -F "\"$identity\"" >/dev/null
print "Created local-only signing identity: $identity"
