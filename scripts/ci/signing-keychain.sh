#!/bin/bash
# CI only (release.yml, figcraft.yml): temporary keychain with the Developer ID Application identity, plus the
# notary API key at $RUNNER_TEMP/notary-key.p8. Env: P12_BASE64, P12_PASSWORD, NOTARY_KEY_P8 (secrets, docs/release.md).
# The workflow deletes $RUNNER_TEMP/collie-signing.keychain-db and the keys in an `if: always()` step.
set -euo pipefail
[ -n "${P12_BASE64:-}" ] && [ -n "${P12_PASSWORD:-}" ] && [ -n "${NOTARY_KEY_P8:-}" ] \
  || { echo "::error::missing secrets (docs/release.md)"; exit 1; }
: "${RUNNER_TEMP:?RUNNER_TEMP not set (GitHub Actions only)}"
KC="$RUNNER_TEMP/collie-signing.keychain-db"
KC_PW="$(openssl rand -base64 32)"
echo "::add-mask::$KC_PW"
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PW" "$KC"
printf '%s' "$P12_BASE64" | base64 --decode > "$RUNNER_TEMP/developer-id.p12"
security import "$RUNNER_TEMP/developer-id.p12" -k "$KC" -P "$P12_PASSWORD" -f pkcs12 -T /usr/bin/codesign
rm -f "$RUNNER_TEMP/developer-id.p12"
# Developer ID G2 intermediate: without it the identity is not "valid" when the .p12 lacks the chain
curl -fsSL --retry 3 -o "$RUNNER_TEMP/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
security import "$RUNNER_TEMP/DeveloperIDG2CA.cer" -k "$KC"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null
# shellcheck disable=SC2046 # word-split the existing keychain list on purpose
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$KC"
printf '%s\n' "$NOTARY_KEY_P8" > "$RUNNER_TEMP/notary-key.p8"
