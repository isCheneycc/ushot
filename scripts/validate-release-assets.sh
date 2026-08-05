#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

DIRECTORY=""
VERSION=""
BUILD_NUMBER=""
TAG=""
MODE="public-adhoc"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --directory) DIRECTORY="${2:?--directory requires a value}"; shift 2 ;;
    --mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
    --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -d "$DIRECTORY" ]] || release_die "Asset directory not found: $DIRECTORY"
[[ "$MODE" == "public-adhoc" || "$MODE" == "developer-id" ]] \
  || release_die "Asset validation mode must be public-adhoc or developer-id."
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_tag "$TAG" "$VERSION"
release_require_command plutil
release_require_command codesign
release_require_command cmp
release_require_command ditto
release_require_command dwarfdump
release_require_command file
release_require_command find
release_require_command hdiutil
release_require_command readlink
release_require_command sort
release_require_command stat
release_require_command zipinfo

DMG_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dmg"
ZIP_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.zip"
DSYM_ZIP_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dSYM.zip"
MANIFEST_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.release-manifest.json"
CHECKSUMS_NAME="SHA256SUMS.txt"

for name in "$DMG_NAME" "$ZIP_NAME" "$DSYM_ZIP_NAME" "$MANIFEST_NAME" "$CHECKSUMS_NAME"; do
  [[ -s "$DIRECTORY/$name" ]] || release_die "Required release asset is missing or empty: $DIRECTORY/$name"
done

EXPECTED_CHECKSUM_NAMES="$(printf '%s\n' "$DMG_NAME" "$ZIP_NAME" "$DSYM_ZIP_NAME" "$MANIFEST_NAME" | sort)"
ACTUAL_CHECKSUM_NAMES="$(awk '{print $2}' "$DIRECTORY/$CHECKSUMS_NAME" | sort)"
[[ "$ACTUAL_CHECKSUM_NAMES" == "$EXPECTED_CHECKSUM_NAMES" ]] \
  || release_die "SHA256SUMS.txt does not contain the exact expected asset set."
while read -r checksum_digest checksum_name checksum_extra; do
  [[ "$checksum_digest" =~ ^[0-9a-f]{64}$ && -n "$checksum_name" && -z "${checksum_extra:-}" ]] \
    || release_die "SHA256SUMS.txt contains a malformed line for ${checksum_name:-unknown}."
done < "$DIRECTORY/$CHECKSUMS_NAME"

(
  cd "$DIRECTORY"
  shasum -a 256 -c "$CHECKSUMS_NAME"
)
plutil -p "$DIRECTORY/$MANIFEST_NAME" >/dev/null
[[ "$(plutil -extract schemaVersion raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "1" ]] \
  || release_die "Release manifest schema version mismatch."
[[ "$(plutil -extract version raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$VERSION" ]] \
  || release_die "Release manifest version mismatch."
[[ "$(plutil -extract buildNumber raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$BUILD_NUMBER" ]] \
  || release_die "Release manifest build number mismatch."
[[ "$(plutil -extract tag raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$TAG" ]] \
  || release_die "Release manifest tag mismatch."
[[ "$(plutil -extract bundleIdentifier raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$USHOT_BUNDLE_IDENTIFIER" ]] \
  || release_die "Release manifest bundle identifier mismatch."
[[ "$(plutil -extract product raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$USHOT_PRODUCT_NAME" ]] \
  || release_die "Release manifest product mismatch."
[[ "$(plutil -extract architecture raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$USHOT_ARCHITECTURE" ]] \
  || release_die "Release manifest architecture mismatch."
[[ "$(plutil -extract appcastURL raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$USHOT_APPCAST_URL" ]] \
  || release_die "Release manifest appcast URL mismatch."

EXPECTED_SIGNING_MODE="ad-hoc"
EXPECTED_HARDENED_RUNTIME="false"
if [[ "$MODE" == "developer-id" ]]; then
  EXPECTED_SIGNING_MODE="developer-id"
  EXPECTED_HARDENED_RUNTIME="true"
fi
[[ "$(plutil -extract signing.mode raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$EXPECTED_SIGNING_MODE" ]] \
  || release_die "Release manifest signing mode mismatch."
[[ "$(plutil -extract signing.hardenedRuntime raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$EXPECTED_HARDENED_RUNTIME" ]] \
  || release_die "Release manifest Hardened Runtime value mismatch."
[[ "$(plutil -extract signing.developmentEntitlements raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "false" ]] \
  || release_die "Release manifest must reject development entitlements."

ASSET_NAMES=("$DMG_NAME" "$ZIP_NAME" "$DSYM_ZIP_NAME")
ASSET_PURPOSES=("initial-install" "sparkle-update" "debug-symbols")
for index in 0 1 2; do
  name="${ASSET_NAMES[$index]}"
  [[ "$(plutil -extract "assets.$index.name" raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$name" ]] \
    || release_die "Release manifest asset name mismatch at index $index."
  [[ "$(plutil -extract "assets.$index.bytes" raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$(release_file_size "$DIRECTORY/$name")" ]] \
    || release_die "Release manifest asset size mismatch for $name."
  [[ "$(plutil -extract "assets.$index.sha256" raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "$(release_sha256 "$DIRECTORY/$name")" ]] \
    || release_die "Release manifest asset checksum mismatch for $name."
  [[ "$(plutil -extract "assets.$index.purpose" raw -o - "$DIRECTORY/$MANIFEST_NAME")" == "${ASSET_PURPOSES[$index]}" ]] \
    || release_die "Release manifest asset purpose mismatch for $name."
done
if plutil -extract assets.3 xml1 -o - "$DIRECTORY/$MANIFEST_NAME" >/dev/null 2>&1; then
  release_die "Release manifest must contain exactly three asset records."
fi

VALIDATION_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/ushot-assets.XXXXXX")"
ZIP_EXTRACT_ROOT="$VALIDATION_WORKSPACE/zip"
DSYM_EXTRACT_ROOT="$VALIDATION_WORKSPACE/dsym"
DMG_MOUNT_ROOT="$VALIDATION_WORKSPACE/dmg"
DMG_ATTACHED=NO
cleanup() {
  if [[ "$DMG_ATTACHED" == "YES" ]]; then
    if ! hdiutil detach "$DMG_MOUNT_ROOT" >/dev/null 2>&1; then
      release_warn "Could not detach validation mount; preserving its workspace: $DMG_MOUNT_ROOT"
      return 0
    fi
    DMG_ATTACHED=NO
  fi
  rm -rf "$VALIDATION_WORKSPACE"
}
trap cleanup EXIT
mkdir -p "$ZIP_EXTRACT_ROOT" "$DSYM_EXTRACT_ROOT" "$DMG_MOUNT_ROOT"

validate_archive_paths() {
  local archive_label="$1"
  local entries="$2"
  local entry
  local path_without_trailing_slash

  while IFS= read -r entry; do
    path_without_trailing_slash="${entry%/}"
    [[ -n "$path_without_trailing_slash" && "$path_without_trailing_slash" != /* ]] \
      || release_die "$archive_label contains an empty or absolute path: $entry"
    [[ "$path_without_trailing_slash" != *\\* && "$path_without_trailing_slash" != *//* ]] \
      || release_die "$archive_label contains a noncanonical path: $entry"
    case "/$path_without_trailing_slash/" in
      */../*|*/./*) release_die "$archive_label contains a dot or parent path component: $entry" ;;
    esac
  done <<< "$entries"
}

validate_bundle_symlinks() {
  local bundle_path="$1"
  local symlink_path
  local symlink_target

  while IFS= read -r -d '' symlink_path; do
    symlink_target="$(readlink "$symlink_path")"
    [[ -n "$symlink_target" \
        && "$symlink_target" != /* \
        && "$symlink_target" != *\\* \
        && "$symlink_target" != *$'\n'* \
        && "$symlink_target" != *$'\r'* \
        && "$symlink_target" != *$'\t'* ]] \
      || release_die "Bundle contains an empty, absolute or noncanonical symlink: $symlink_path"
    case "/$symlink_target/" in
      */../*|*/./*|*//*) release_die "Bundle symlink may escape its canonical relative path: $symlink_path -> $symlink_target" ;;
    esac
  done < <(find "$bundle_path" -type l -print0)
}

write_bundle_tree_manifest() {
  local bundle_path="$1"
  local output_path="$2"
  local entry
  local entry_mode
  local entry_size
  local entry_digest
  local symlink_target

  [[ -d "$bundle_path" && ! -L "$bundle_path" ]] \
    || release_die "Bundle tree manifest requires one real directory: $bundle_path"

  (
    cd "$bundle_path"
    while IFS= read -r -d '' entry; do
      entry_mode="$(stat -f '%Lp' "$entry")"
      if [[ -L "$entry" ]]; then
        symlink_target="$(readlink "$entry")"
        printf 'symlink\0%s\0%s\0%s\0' \
          "$entry" "$entry_mode" "$symlink_target"
      elif [[ -d "$entry" ]]; then
        printf 'directory\0%s\0%s\0' "$entry" "$entry_mode"
      elif [[ -f "$entry" ]]; then
        entry_size="$(stat -f '%z' "$entry")"
        entry_digest="$(release_sha256 "$entry")"
        printf 'file\0%s\0%s\0%s\0%s\0' \
          "$entry" "$entry_mode" "$entry_size" "$entry_digest"
      else
        release_die "Bundle contains an unsupported filesystem object: $bundle_path/${entry#./}"
      fi
    done < <(find . -print0 | LC_ALL=C sort -z)
  ) > "$output_path"
}

compare_bundle_trees() {
  local first_bundle="$1"
  local second_bundle="$2"
  local first_manifest="$VALIDATION_WORKSPACE/first-bundle-tree.manifest"
  local second_manifest="$VALIDATION_WORKSPACE/second-bundle-tree.manifest"

  write_bundle_tree_manifest "$first_bundle" "$first_manifest"
  write_bundle_tree_manifest "$second_bundle" "$second_manifest"
  cmp -s "$first_manifest" "$second_manifest" \
    || release_die "ZIP and DMG differ by path, filesystem type, mode, symlink target, size or SHA-256 content."
}

ZIP_ENTRIES="$(zipinfo -1 "$DIRECTORY/$ZIP_NAME")"
[[ -n "$ZIP_ENTRIES" ]] || release_die "Sparkle ZIP is empty: $ZIP_NAME"
validate_archive_paths "Sparkle ZIP" "$ZIP_ENTRIES"
UNEXPECTED_ZIP_ENTRIES="$(printf '%s\n' "$ZIP_ENTRIES" | grep -Ev "^($USHOT_APP_BUNDLE/|__MACOSX/$|__MACOSX/$USHOT_APP_BUNDLE/)" || true)"
[[ -z "$UNEXPECTED_ZIP_ENTRIES" ]] \
  || release_die "Sparkle ZIP contains entries outside $USHOT_APP_BUNDLE: $UNEXPECTED_ZIP_ENTRIES"
DUPLICATE_ZIP_ENTRIES="$(printf '%s\n' "$ZIP_ENTRIES" | sort | uniq -d)"
[[ -z "$DUPLICATE_ZIP_ENTRIES" ]] \
  || release_die "Sparkle ZIP contains duplicate paths: $DUPLICATE_ZIP_ENTRIES"
ditto -x -k "$DIRECTORY/$ZIP_NAME" "$ZIP_EXTRACT_ROOT"
ZIP_APP="$ZIP_EXTRACT_ROOT/$USHOT_APP_BUNDLE"
[[ -d "$ZIP_APP" && ! -L "$ZIP_APP" ]] \
  || release_die "Sparkle ZIP did not extract one real $USHOT_APP_BUNDLE directory."
validate_bundle_symlinks "$ZIP_APP"
release_validate_app_identity "$ZIP_APP" "$VERSION" "$BUILD_NUMBER"
release_verify_signature_mode "$ZIP_APP" "$MODE"

DSYM_ENTRIES="$(zipinfo -1 "$DIRECTORY/$DSYM_ZIP_NAME")"
[[ -n "$DSYM_ENTRIES" ]] || release_die "dSYM ZIP is empty: $DSYM_ZIP_NAME"
validate_archive_paths "dSYM ZIP" "$DSYM_ENTRIES"
UNEXPECTED_DSYM_ENTRIES="$(printf '%s\n' "$DSYM_ENTRIES" | grep -Ev "^($USHOT_APP_BUNDLE\\.dSYM/|__MACOSX/$|__MACOSX/$USHOT_APP_BUNDLE\\.dSYM/)" || true)"
[[ -z "$UNEXPECTED_DSYM_ENTRIES" ]] \
  || release_die "dSYM ZIP contains entries outside $USHOT_APP_BUNDLE.dSYM: $UNEXPECTED_DSYM_ENTRIES"
DUPLICATE_DSYM_ENTRIES="$(printf '%s\n' "$DSYM_ENTRIES" | sort | uniq -d)"
[[ -z "$DUPLICATE_DSYM_ENTRIES" ]] \
  || release_die "dSYM ZIP contains duplicate paths: $DUPLICATE_DSYM_ENTRIES"
ditto -x -k "$DIRECTORY/$DSYM_ZIP_NAME" "$DSYM_EXTRACT_ROOT"
EXTRACTED_DSYM="$DSYM_EXTRACT_ROOT/$USHOT_APP_BUNDLE.dSYM"
[[ -d "$EXTRACTED_DSYM" && ! -L "$EXTRACTED_DSYM" ]] \
  || release_die "dSYM ZIP did not extract one real $USHOT_APP_BUNDLE.dSYM directory."
validate_bundle_symlinks "$EXTRACTED_DSYM"
release_verify_dsym "$ZIP_APP" "$EXTRACTED_DSYM"

hdiutil verify "$DIRECTORY/$DMG_NAME" >/dev/null
if [[ "$MODE" == "public-adhoc" ]]; then
  if codesign --display "$DIRECTORY/$DMG_NAME" >/dev/null 2>&1; then
    release_die "Public DMG must remain unsigned."
  fi
else
  DMG_SIGNATURE="$(codesign --display --verbose=4 "$DIRECTORY/$DMG_NAME" 2>&1)" \
    || release_die "Developer ID DMG has no valid signature."
  grep -q '^Authority=Developer ID Application' <<<"$DMG_SIGNATURE" \
    || release_die "Developer ID DMG does not have a Developer ID Application authority."
  codesign --verify --strict --verbose=2 "$DIRECTORY/$DMG_NAME"
fi

hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$DMG_MOUNT_ROOT" \
  "$DIRECTORY/$DMG_NAME" \
  >/dev/null
DMG_ATTACHED=YES
EXPECTED_DMG_ROOT_NAMES="$(printf '%s\n' Applications "$USHOT_APP_BUNDLE" | sort)"
ACTUAL_DMG_ROOT_NAMES="$(find "$DMG_MOUNT_ROOT" -mindepth 1 -maxdepth 1 -exec basename '{}' ';' | sort)"
[[ "$ACTUAL_DMG_ROOT_NAMES" == "$EXPECTED_DMG_ROOT_NAMES" ]] \
  || release_die "DMG root does not contain exactly $USHOT_APP_BUNDLE and the Applications link; found: $ACTUAL_DMG_ROOT_NAMES"
[[ -L "$DMG_MOUNT_ROOT/Applications" ]] \
  || release_die "DMG Applications entry is not a symbolic link."
[[ "$(readlink "$DMG_MOUNT_ROOT/Applications")" == "/Applications" ]] \
  || release_die "DMG Applications link does not target /Applications."
DMG_APP="$DMG_MOUNT_ROOT/$USHOT_APP_BUNDLE"
[[ -d "$DMG_APP" && ! -L "$DMG_APP" ]] \
  || release_die "DMG does not contain one real $USHOT_APP_BUNDLE directory."
validate_bundle_symlinks "$DMG_APP"
release_validate_app_identity "$DMG_APP" "$VERSION" "$BUILD_NUMBER"
release_verify_signature_mode "$DMG_APP" "$MODE"
release_verify_dsym "$DMG_APP" "$EXTRACTED_DSYM"
compare_bundle_trees "$ZIP_APP" "$DMG_APP"
hdiutil detach "$DMG_MOUNT_ROOT" >/dev/null
DMG_ATTACHED=NO

release_log "Validated exact release asset set for $TAG."
