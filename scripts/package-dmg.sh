#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build/release}"
ARTIFACTS_DIR="$BUILD_ROOT/artifacts"
APP_NAME="${APP_NAME:-UshotApp}"
APP_PATH="${1:-$ARTIFACTS_DIR/$APP_NAME.app}"
VERSION="${MARKETING_VERSION:-0.1.0}"
DMG_PATH="${DMG_PATH:-$ARTIFACTS_DIR/$APP_NAME-$VERSION.dmg}"
ALLOW_UNSTABLE_LOCAL_SIGNING="${ALLOW_UNSTABLE_LOCAL_SIGNING:-NO}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: App bundle not found at $APP_PATH. Run scripts/build-release.sh first." >&2
  exit 1
fi
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "error: hdiutil is unavailable." >&2
  exit 1
fi

if [[ "$ALLOW_UNSTABLE_LOCAL_SIGNING" != "YES" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
  TEAM_IDENTIFIER="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE_DETAILS")"
  DESIGNATED_REQUIREMENT="$(codesign --display --requirements - "$APP_PATH" 2>&1 | sed -n 's/^designated => //p')"
  if [[ -z "$TEAM_IDENTIFIER" || "$TEAM_IDENTIFIER" == "not set" ]] \
      || grep -q '^Signature=adhoc$' <<<"$SIGNATURE_DETAILS" \
      || [[ -z "$DESIGNATED_REQUIREMENT" ]]; then
    echo "error: Refusing to package an app without a stable code identity." >&2
    echo "error: Build with scripts/build-release.sh after configuring Config/Local.xcconfig." >&2
    exit 1
  fi
  echo "Stable enclosed app signature verified: team=$TEAM_IDENTIFIER"
fi

mkdir -p "$ARTIFACTS_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ushot-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

ditto --rsrc --extattr "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
else
  echo "warning: Produced an unsigned local DMG containing the verified signed app." >&2
fi

echo "$DMG_PATH"
