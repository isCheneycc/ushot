#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

MODE="public-adhoc"
VERSION=""
BUILD_NUMBER=""
TAG=""
APP_PATH=""
DSYM_PATH=""
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build/release}"

usage() {
  printf '%s\n' "usage: $0 --version X.Y.Z --build-number N --tag vX.Y.Z [--mode public-adhoc|developer-id] [--app PATH] [--dsym PATH]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
    --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
    --app) APP_PATH="${2:?--app requires a value}"; shift 2 ;;
    --dsym) DSYM_PATH="${2:?--dsym requires a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ "$MODE" == "public-adhoc" || "$MODE" == "developer-id" ]] \
  || release_die "Release packaging supports only public-adhoc or the future developer-id mode."
[[ -n "$VERSION" && -n "$BUILD_NUMBER" && -n "$TAG" ]] || { usage >&2; exit 1; }
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_tag "$TAG" "$VERSION"
release_validate_source_settings "$PROJECT_ROOT" "$VERSION" "$BUILD_NUMBER"

ARTIFACTS_DIR="$BUILD_ROOT/$MODE/artifacts"
if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$ARTIFACTS_DIR/$USHOT_APP_BUNDLE"
else
  ARTIFACTS_DIR="$(dirname "$APP_PATH")"
fi
if [[ -z "$DSYM_PATH" ]]; then
  DSYM_PATH="$ARTIFACTS_DIR/$USHOT_APP_BUNDLE.dSYM"
fi
release_validate_app_identity "$APP_PATH" "$VERSION" "$BUILD_NUMBER"
release_verify_signature_mode "$APP_PATH" "$MODE"
release_verify_dsym "$APP_PATH" "$DSYM_PATH"
release_require_command ditto
release_require_command hdiutil
release_require_command zipinfo

DMG_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dmg"
ZIP_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.zip"
DSYM_ZIP_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dSYM.zip"
MANIFEST_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.release-manifest.json"
CHECKSUMS_NAME="SHA256SUMS.txt"

DMG_PATH="$ARTIFACTS_DIR/$DMG_NAME"
ZIP_PATH="$ARTIFACTS_DIR/$ZIP_NAME"
DSYM_ZIP_PATH="$ARTIFACTS_DIR/$DSYM_ZIP_NAME"
MANIFEST_PATH="$ARTIFACTS_DIR/$MANIFEST_NAME"
CHECKSUMS_PATH="$ARTIFACTS_DIR/$CHECKSUMS_NAME"

"$SCRIPT_DIR/package-dmg.sh" \
  --mode "$MODE" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --app "$APP_PATH" \
  --output "$DMG_PATH"

rm -f "$ZIP_PATH" "$DSYM_ZIP_PATH" "$MANIFEST_PATH" "$CHECKSUMS_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
ditto -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP_PATH"

UNEXPECTED_ZIP_ENTRIES="$(zipinfo -1 "$ZIP_PATH" | grep -Ev "^($USHOT_APP_BUNDLE/|__MACOSX/$|__MACOSX/$USHOT_APP_BUNDLE/)" || true)"
if [[ -n "$UNEXPECTED_ZIP_ENTRIES" ]]; then
  release_die "Sparkle ZIP contains entries outside $USHOT_APP_BUNDLE."
fi
zipinfo -1 "$ZIP_PATH" | grep "^$USHOT_APP_BUNDLE/Contents/MacOS/$USHOT_EXECUTABLE_NAME$" >/dev/null \
  || release_die "Sparkle ZIP does not contain the expected Ushot executable."
zipinfo -1 "$DSYM_ZIP_PATH" | grep "^$USHOT_APP_BUNDLE.dSYM/" >/dev/null \
  || release_die "dSYM archive does not contain $USHOT_APP_BUNDLE.dSYM."

DMG_SHA="$(release_sha256 "$DMG_PATH")"
ZIP_SHA="$(release_sha256 "$ZIP_PATH")"
DSYM_SHA="$(release_sha256 "$DSYM_ZIP_PATH")"
HARDENED_RUNTIME=true
SIGNING_MODE="developer-id"
if [[ "$MODE" == "public-adhoc" ]]; then
  HARDENED_RUNTIME=false
  SIGNING_MODE="ad-hoc"
fi

cat > "$MANIFEST_PATH" <<EOF
{
  "schemaVersion": 1,
  "product": "$USHOT_PRODUCT_NAME",
  "bundleIdentifier": "$USHOT_BUNDLE_IDENTIFIER",
  "version": "$VERSION",
  "buildNumber": "$BUILD_NUMBER",
  "tag": "$TAG",
  "architecture": "$USHOT_ARCHITECTURE",
  "appcastURL": "$USHOT_APPCAST_URL",
  "signing": {
    "mode": "$SIGNING_MODE",
    "hardenedRuntime": $HARDENED_RUNTIME,
    "developmentEntitlements": false
  },
  "assets": [
    {"name": "$DMG_NAME", "bytes": $(release_file_size "$DMG_PATH"), "sha256": "$DMG_SHA", "purpose": "initial-install"},
    {"name": "$ZIP_NAME", "bytes": $(release_file_size "$ZIP_PATH"), "sha256": "$ZIP_SHA", "purpose": "sparkle-update"},
    {"name": "$DSYM_ZIP_NAME", "bytes": $(release_file_size "$DSYM_ZIP_PATH"), "sha256": "$DSYM_SHA", "purpose": "debug-symbols"}
  ]
}
EOF

(
  cd "$ARTIFACTS_DIR"
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" "$DSYM_ZIP_NAME" "$MANIFEST_NAME" > "$CHECKSUMS_NAME"
  shasum -a 256 -c "$CHECKSUMS_NAME"
)

"$SCRIPT_DIR/validate-release-assets.sh" \
  --directory "$ARTIFACTS_DIR" \
  --mode "$MODE" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --tag "$TAG"

release_log "Release assets are ready in $ARTIFACTS_DIR"
printf '%s\n' "$DMG_PATH" "$ZIP_PATH" "$DSYM_ZIP_PATH" "$MANIFEST_PATH" "$CHECKSUMS_PATH"
