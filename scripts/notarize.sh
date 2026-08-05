#!/bin/bash
set -euo pipefail

DMG_PATH="${1:-}"
if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "usage: $0 /absolute/path/to/UshotApp.dmg" >&2
  exit 1
fi
if ! xcrun notarytool --help >/dev/null 2>&1; then
  echo "error: notarytool is unavailable; install and select a full Xcode." >&2
  exit 1
fi

if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
    --wait
else
  : "${APPLE_ID:?APPLE_ID is required when NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required when NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
  : "${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD is required when NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "$DMG_PATH"
