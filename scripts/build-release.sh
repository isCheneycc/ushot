#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

MODE="local-signed"
VERSION=""
BUILD_NUMBER=""
CONFIGURATION="Release"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build/release}"

usage() {
  printf '%s\n' \
    "usage: $0 [--mode local-signed|public-adhoc|developer-id] [--version X.Y.Z] [--build-number N]" \
    "" \
    "local-signed  Stable Apple Development identity for /Applications/Ushot.app." \
    "public-adhoc  Public GitHub artifact without Developer ID; disables Hardened Runtime." \
    "developer-id Future optional Developer ID path; requires explicit environment values."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || release_die "--mode requires a value."
      MODE="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || release_die "--version requires a value."
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || release_die "--build-number requires a value."
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      release_die "Unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  local-signed|public-adhoc|developer-id) ;;
  *) release_die "Unsupported build mode: $MODE" ;;
esac

if [[ -z "$VERSION" ]]; then
  VERSION="$(release_xcconfig_value MARKETING_VERSION "$PROJECT_ROOT/Config/Base.xcconfig")"
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(release_xcconfig_value CURRENT_PROJECT_VERSION "$PROJECT_ROOT/Config/Base.xcconfig")"
fi
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_source_settings "$PROJECT_ROOT" "$VERSION" "$BUILD_NUMBER"
release_require_command xcodebuild
release_require_command codesign
release_require_command dwarfdump
release_require_command file

if ! xcodebuild -version >/dev/null 2>&1; then
  release_die "A full Xcode installation is required. Select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

MODE_ROOT="$BUILD_ROOT/$MODE"
DERIVED_DATA="$MODE_ROOT/DerivedData"
ARTIFACTS_DIR="$MODE_ROOT/artifacts"
mkdir -p "$DERIVED_DATA" "$ARTIFACTS_DIR"

SIGNING_ARGUMENTS=()
case "$MODE" in
  local-signed)
    SIGNING_ARGUMENTS=(
      CODE_SIGNING_ALLOWED=YES
      CODE_SIGNING_REQUIRED=YES
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
      ENABLE_HARDENED_RUNTIME=YES
    )
    release_log "Building local-signed Release with the configured Apple Development identity."
    ;;
  public-adhoc)
    SIGNING_ARGUMENTS=(
      CODE_SIGNING_ALLOWED=YES
      CODE_SIGNING_REQUIRED=YES
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY=-
      DEVELOPMENT_TEAM=
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
      ENABLE_HARDENED_RUNTIME=NO
    )
    release_warn "Building the intentional public ad-hoc distribution without Hardened Runtime."
    release_warn "This is required because an ad-hoc host may not load Sparkle under Library Validation."
    ;;
  developer-id)
    : "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required for developer-id mode}"
    : "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required for developer-id mode}"
    SIGNING_ARGUMENTS=(
      CODE_SIGNING_ALLOWED=YES
      CODE_SIGNING_REQUIRED=YES
      CODE_SIGN_STYLE=Manual
      "CODE_SIGN_IDENTITY=$DEVELOPER_ID_APPLICATION"
      "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
      ENABLE_HARDENED_RUNTIME=YES
      "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
    release_log "Building optional Developer ID Release."
    ;;
esac

xcodebuild \
  -project "$PROJECT_ROOT/ScreenshotApp.xcodeproj" \
  -scheme ScreenshotApp \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$USHOT_ARCHITECTURE" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  "${SIGNING_ARGUMENTS[@]}" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$USHOT_APP_BUNDLE"
BUILT_DSYM="$DERIVED_DATA/Build/Products/$CONFIGURATION/$USHOT_APP_BUNDLE.dSYM"
release_validate_app_identity "$BUILT_APP" "$VERSION" "$BUILD_NUMBER"
release_verify_signature_mode "$BUILT_APP" "$MODE"
release_verify_dsym "$BUILT_APP" "$BUILT_DSYM"

OUTPUT_APP="$ARTIFACTS_DIR/$USHOT_APP_BUNDLE"
OUTPUT_DSYM="$ARTIFACTS_DIR/$USHOT_APP_BUNDLE.dSYM"
if [[ -e "$OUTPUT_APP" ]]; then
  rm -rf "$OUTPUT_APP"
fi
if [[ -e "$OUTPUT_DSYM" ]]; then
  rm -rf "$OUTPUT_DSYM"
fi
ditto --rsrc --extattr "$BUILT_APP" "$OUTPUT_APP"
ditto --rsrc --extattr "$BUILT_DSYM" "$OUTPUT_DSYM"

release_validate_app_identity "$OUTPUT_APP" "$VERSION" "$BUILD_NUMBER"
release_verify_signature_mode "$OUTPUT_APP" "$MODE"
release_verify_dsym "$OUTPUT_APP" "$OUTPUT_DSYM"
release_log "Build complete: mode=$MODE version=$VERSION build=$BUILD_NUMBER"
printf '%s\n' "$OUTPUT_APP"
