#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

MODE="local-signed"
VERSION=""
BUILD_NUMBER=""
APP_PATH=""
OUTPUT_PATH=""
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build/release}"

usage() {
  printf '%s\n' "usage: $0 [--mode local-signed|public-adhoc|developer-id] [--version X.Y.Z] [--build-number N] [--app PATH] [--output PATH]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
    --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    --app) APP_PATH="${2:?--app requires a value}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:?--output requires a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

case "$MODE" in
  local-signed|public-adhoc|developer-id) ;;
  *) release_die "Unsupported package mode: $MODE" ;;
esac

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$BUILD_ROOT/$MODE/artifacts/$USHOT_APP_BUNDLE"
fi
[[ -d "$APP_PATH" ]] || release_die "App bundle not found: $APP_PATH"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ -z "$VERSION" ]]; then
  VERSION="$(release_plist_value "$INFO_PLIST" CFBundleShortVersionString)"
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(release_plist_value "$INFO_PLIST" CFBundleVersion)"
fi
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_app_identity "$APP_PATH" "$VERSION" "$BUILD_NUMBER"
release_verify_signature_mode "$APP_PATH" "$MODE"
release_require_command hdiutil

ARTIFACTS_DIR="$(dirname "$APP_PATH")"
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$ARTIFACTS_DIR/$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dmg"
fi
[[ "$(basename "$OUTPUT_PATH")" == "$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dmg" ]] \
  || release_die "DMG filename must be $USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dmg"
mkdir -p "$(dirname "$OUTPUT_PATH")"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ushot-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

ditto --rsrc --extattr "$APP_PATH" "$STAGING_DIR/$USHOT_APP_BUNDLE"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$USHOT_PRODUCT_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"
hdiutil verify "$OUTPUT_PATH"

case "$MODE" in
  developer-id)
    : "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required for developer-id mode}"
    codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$OUTPUT_PATH"
    codesign --verify --verbose=2 "$OUTPUT_PATH"
    ;;
  public-adhoc)
    if codesign --display "$OUTPUT_PATH" >/dev/null 2>&1; then
      release_die "Public DMG must remain unsigned when Developer ID is unavailable."
    fi
    release_warn "Produced an unsigned, unnotarized public DMG containing the verified ad-hoc app."
    ;;
  local-signed)
    release_log "Produced an unsigned local DMG containing the verified Apple Development-signed app."
    ;;
esac

printf '%s\n' "$OUTPUT_PATH"
