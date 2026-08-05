#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

DMG_PATH="${1:-}"
if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "usage: $0 /absolute/path/to/Ushot-X.Y.Z-arm64.dmg" >&2
  exit 1
fi
if ! xcrun notarytool --help >/dev/null 2>&1; then
  release_die "notarytool is unavailable; install and select a full Xcode."
fi

DMG_SIGNATURE="$(codesign --display --verbose=4 "$DMG_PATH" 2>&1)" \
  || release_die "Notarization is only supported for the future Developer ID path; the DMG is unsigned."
grep -q '^Authority=Developer ID Application' <<<"$DMG_SIGNATURE" \
  || release_die "Notarization requires a Developer ID Application-signed DMG."

: "${NOTARYTOOL_KEYCHAIN_PROFILE:?NOTARYTOOL_KEYCHAIN_PROFILE is required; raw Apple credentials are forbidden}"
if [[ -n "${APPLE_ID:-}" || -n "${APPLE_TEAM_ID:-}" || -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
  release_die "Raw Apple notarization credentials are forbidden; unset them and use the keychain profile only."
fi
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

release_log "Notarization, stapling and Gatekeeper assessment succeeded: $DMG_PATH"
printf '%s\n' "$DMG_PATH"
