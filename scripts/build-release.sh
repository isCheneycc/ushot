#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/build/release}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
ARTIFACTS_DIR="$BUILD_ROOT/artifacts"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-UshotApp}"
ALLOW_UNSTABLE_LOCAL_SIGNING="${ALLOW_UNSTABLE_LOCAL_SIGNING:-NO}"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: A full Xcode installation is required. Select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

mkdir -p "$DERIVED_DATA" "$ARTIFACTS_DIR"

SIGNING_ARGUMENTS=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES)
REQUIRE_STABLE_SIGNATURE=YES
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "error: DEVELOPMENT_TEAM is required when DEVELOPER_ID_APPLICATION is set." >&2
    exit 1
  fi
  SIGNING_ARGUMENTS=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$DEVELOPER_ID_APPLICATION"
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
elif [[ "$ALLOW_UNSTABLE_LOCAL_SIGNING" == "YES" ]]; then
  SIGNING_ARGUMENTS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  REQUIRE_STABLE_SIGNATURE=NO
fi

xcodebuild \
  -project "$PROJECT_ROOT/ScreenshotApp.xcodeproj" \
  -scheme ScreenshotApp \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  "${SIGNING_ARGUMENTS[@]}" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: Expected app bundle was not produced at $BUILT_APP" >&2
  exit 1
fi

if [[ "$REQUIRE_STABLE_SIGNATURE" == "YES" ]]; then
  codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
  SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$BUILT_APP" 2>&1)"
  TEAM_IDENTIFIER="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE_DETAILS")"
  if [[ -z "$TEAM_IDENTIFIER" || "$TEAM_IDENTIFIER" == "not set" ]]; then
    echo "error: Release app has no stable TeamIdentifier. Configure Config/Local.xcconfig with an Apple Development identity." >&2
    exit 1
  fi
  if grep -q '^Signature=adhoc$' <<<"$SIGNATURE_DETAILS"; then
    echo "error: Release app is ad-hoc signed. Refusing an artifact that would invalidate macOS privacy permissions." >&2
    exit 1
  fi
  DESIGNATED_REQUIREMENT="$(codesign --display --requirements - "$BUILT_APP" 2>&1 | sed -n 's/^designated => //p')"
  if [[ -z "$DESIGNATED_REQUIREMENT" ]]; then
    echo "error: Release app has no designated requirement. Refusing an unstable code identity." >&2
    exit 1
  fi
  echo "Stable code signature verified: team=$TEAM_IDENTIFIER"
  echo "Designated requirement: $DESIGNATED_REQUIREMENT"
fi

OUTPUT_APP="$ARTIFACTS_DIR/$APP_NAME.app"
if [[ -e "$OUTPUT_APP" ]]; then
  rm -rf "$OUTPUT_APP"
fi
ditto --rsrc --extattr "$BUILT_APP" "$OUTPUT_APP"

if [[ "$REQUIRE_STABLE_SIGNATURE" == "YES" ]]; then
  codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
else
  echo "warning: Produced an explicitly requested unstable unsigned Release build." >&2
fi

echo "$OUTPUT_APP"
