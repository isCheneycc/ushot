#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

VERSION=""
BUILD_NUMBER=""
TAG=""
ARCHIVE_PATH=""
RELEASE_NOTES_SOURCE=""
EXISTING_APPCAST=""
EXISTING_APPCAST_KIND=""
SITE_DIRECTORY="${SITE_DIRECTORY:-$PROJECT_ROOT/build/pages}"
SPARKLE_BIN=""
KEY_SOURCE="keychain"

usage() {
  printf '%s\n' "usage: $0 --version X.Y.Z --build-number N --tag vX.Y.Z --archive PATH --release-notes PATH --existing-appcast PATH --existing-appcast-kind signed|seed [--site-directory PATH] [--sparkle-bin PATH] [--key-source keychain|stdin]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
    --archive) ARCHIVE_PATH="${2:?--archive requires a value}"; shift 2 ;;
    --release-notes) RELEASE_NOTES_SOURCE="${2:?--release-notes requires a value}"; shift 2 ;;
    --existing-appcast) EXISTING_APPCAST="${2:?--existing-appcast requires a value}"; shift 2 ;;
    --existing-appcast-kind) EXISTING_APPCAST_KIND="${2:?--existing-appcast-kind requires a value}"; shift 2 ;;
    --site-directory) SITE_DIRECTORY="${2:?--site-directory requires a value}"; shift 2 ;;
    --sparkle-bin) SPARKLE_BIN="${2:?--sparkle-bin requires a value}"; shift 2 ;;
    --key-source) KEY_SOURCE="${2:?--key-source requires a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$VERSION" && -n "$BUILD_NUMBER" && -n "$TAG" && -n "$ARCHIVE_PATH" && -n "$RELEASE_NOTES_SOURCE" && -n "$EXISTING_APPCAST" && -n "$EXISTING_APPCAST_KIND" ]] \
  || { usage >&2; exit 1; }
[[ "$KEY_SOURCE" == "keychain" || "$KEY_SOURCE" == "stdin" ]] \
  || release_die "--key-source must be keychain or stdin."
[[ "$EXISTING_APPCAST_KIND" == "signed" || "$EXISTING_APPCAST_KIND" == "seed" ]] \
  || release_die "--existing-appcast-kind must be signed or seed."
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_tag "$TAG" "$VERSION"
[[ -s "$ARCHIVE_PATH" ]] || release_die "Sparkle ZIP is missing or empty: $ARCHIVE_PATH"
[[ "$(basename "$ARCHIVE_PATH")" == "$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.zip" ]] \
  || release_die "Unexpected Sparkle ZIP filename: $(basename "$ARCHIVE_PATH")"
release_validate_release_notes_source "$RELEASE_NOTES_SOURCE"
[[ -s "$EXISTING_APPCAST" ]] || release_die "Existing or seed appcast is missing: $EXISTING_APPCAST"
release_require_command xmllint
xmllint --noout "$EXISTING_APPCAST"

validate_first_release_seed() {
  local appcast_path="$1"
  local channel_xpath="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']"

  xmllint --noout "$appcast_path"
  [[ "$(xmllint --xpath "count(/*[local-name()='rss' and namespace-uri()=''])" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "string(/*[local-name()='rss' and namespace-uri()='']/@version)" "$appcast_path")" == "2.0" ]] \
    || release_die "First-release seed must be an RSS 2.0 document."
  [[ "$(xmllint --xpath "count($channel_xpath)" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "count(//*[local-name()='channel'])" "$appcast_path")" == "1" ]] \
    || release_die "First-release seed must contain exactly one channel."
  [[ "$(xmllint --xpath 'count(//*[local-name()="item"])' "$appcast_path")" == "0" ]] \
    || release_die "First-release seed must not contain any update items."
  [[ "$(xmllint --xpath "count($channel_xpath/*[local-name()='title' and namespace-uri()=''])" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "string($channel_xpath/*[local-name()='title' and namespace-uri()=''])" "$appcast_path")" == "Ushot Updates" ]] \
    || release_die "First-release seed has an unexpected channel title."
  [[ "$(xmllint --xpath "count($channel_xpath/*[local-name()='link' and namespace-uri()=''])" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "string($channel_xpath/*[local-name()='link' and namespace-uri()=''])" "$appcast_path")" == "$USHOT_APPCAST_URL" ]] \
    || release_die "First-release seed has an unexpected channel link."
  [[ "$(xmllint --xpath "count($channel_xpath/*[local-name()='description' and namespace-uri()=''])" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "string($channel_xpath/*[local-name()='description' and namespace-uri()=''])" "$appcast_path")" == "Stable Ushot updates for macOS." ]] \
    || release_die "First-release seed has an unexpected channel description."
  [[ "$(xmllint --xpath "count($channel_xpath/*[local-name()='language' and namespace-uri()=''])" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "string($channel_xpath/*[local-name()='language' and namespace-uri()=''])" "$appcast_path")" == "en" ]] \
    || release_die "First-release seed has an unexpected channel language."
}

validate_canonical_appcast_items() {
  local appcast_path="$1"
  local channel_xpath="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']"
  local item_count
  local total_item_count
  local index
  local item_xpath
  local item_version
  local item_build
  local item_notes
  local installation_type
  local enclosure_url
  local expected_enclosure_url

  [[ "$(xmllint --xpath "count(/*[local-name()='rss' and namespace-uri()=''])" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "string(/*[local-name()='rss' and namespace-uri()='']/@version)" "$appcast_path")" == "2.0" ]] \
    || release_die "Appcast must be an RSS 2.0 document in the empty XML namespace."
  [[ "$(xmllint --xpath "count($channel_xpath)" "$appcast_path")" == "1" \
      && "$(xmllint --xpath "count(//*[local-name()='channel'])" "$appcast_path")" == "1" ]] \
    || release_die "Appcast must contain exactly one canonical RSS channel."
  item_count="$(xmllint --xpath "count($channel_xpath/*[local-name()='item' and namespace-uri()=''])" "$appcast_path")"
  total_item_count="$(xmllint --xpath 'count(//*[local-name()="item"])' "$appcast_path")"
  [[ "$item_count" =~ ^[0-9]+$ ]] \
    || release_die "Appcast has an invalid item count: $item_count"
  [[ "$total_item_count" == "$item_count" ]] \
    || release_die "Appcast contains an item outside the canonical RSS channel or XML namespace."

  for ((index = 1; index <= item_count; index++)); do
    item_xpath="($channel_xpath/*[local-name()='item' and namespace-uri()=''])[$index]"
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$appcast_path")" == "1" \
        && "$(xmllint --xpath "count($item_xpath/*[local-name()='version'])" "$appcast_path")" == "1" ]] \
      || release_die "Appcast item $index must contain exactly one build version."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='shortVersionString' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$appcast_path")" == "1" \
        && "$(xmllint --xpath "count($item_xpath/*[local-name()='shortVersionString'])" "$appcast_path")" == "1" ]] \
      || release_die "Appcast item $index must contain exactly one semantic version."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='enclosure' and namespace-uri()=''])" "$appcast_path")" == "1" \
        && "$(xmllint --xpath "count($item_xpath/*[local-name()='enclosure'])" "$appcast_path")" == "1" ]] \
      || release_die "Appcast item $index must contain exactly one enclosure."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='informationalUpdate'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must not be an informational-only update."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='minimumAutoupdateVersion'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must not be a major upgrade."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='description' and namespace-uri()=''])" "$appcast_path")" == "1" \
        && "$(xmllint --xpath "count($item_xpath/*[local-name()='description'])" "$appcast_path")" == "1" ]] \
      || release_die "Appcast item $index must contain exactly one embedded release-notes description."
    [[ -n "$(xmllint --xpath "normalize-space(string($item_xpath/*[local-name()='description' and namespace-uri()='']))" "$appcast_path")" ]] \
      || release_die "Appcast item $index has empty embedded release notes."
    [[ "$(xmllint --xpath "string($item_xpath/*[local-name()='description' and namespace-uri()='']/@*[local-name()='format' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$appcast_path")" == "markdown" ]] \
      || release_die "Appcast item $index must use embedded Markdown release notes."
    item_notes="$(xmllint --xpath "string($item_xpath/*[local-name()='description' and namespace-uri()=''])" "$appcast_path")"
    release_validate_release_notes_content "$item_notes"
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='releaseNotesLink'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must not contain detached release notes."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='link'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must not contain an informational link."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='fullReleaseNotesLink'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must not contain an unsigned full-release-notes link."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='deltas'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must not contain a delta update outside the canonical full-archive policy."
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='enclosure']/@*[local-name()='deltaFrom' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must not be a delta child update."

    installation_type="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='installationType' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$appcast_path")"
    [[ -z "$installation_type" || "$installation_type" == "application" ]] \
      || release_die "Appcast item $index must use the application installation type."
    [[ "$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure' and namespace-uri()='']/@type)" "$appcast_path")" == "application/octet-stream" ]] \
      || release_die "Appcast item $index must use an application archive enclosure."
    [[ -n "$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure' and namespace-uri()='']/@length)" "$appcast_path")" ]] \
      || release_die "Appcast item $index must declare its archive length."
    [[ -n "$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='edSignature' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$appcast_path")" ]] \
      || release_die "Appcast item $index must carry an EdDSA archive signature."

    item_version="$(xmllint --xpath "string($item_xpath/*[local-name()='shortVersionString' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$appcast_path")"
    item_build="$(xmllint --xpath "string($item_xpath/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$appcast_path")"
    release_validate_version "$item_version"
    release_validate_build_number "$item_build"

    enclosure_url="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure' and namespace-uri()='']/@url)" "$appcast_path")"
    expected_enclosure_url="https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/v$item_version/$USHOT_PRODUCT_NAME-$item_version-$USHOT_ARCHITECTURE.zip"
    [[ "$enclosure_url" == "$expected_enclosure_url" ]] \
      || release_die "Appcast item $index has a noncanonical enclosure URL: $enclosure_url"
  done
}

canonicalize_site_directory() {
  local requested_path="$1"
  local relative_path
  local build_root="$PROJECT_ROOT/build"
  local candidate_path
  local current_path
  local component
  local canonical_build_root
  local canonical_parent
  local -a path_components=()

  case "$requested_path" in
    "$build_root"/*)
      relative_path="${requested_path#"$build_root"/}"
      ;;
    build/*)
      relative_path="${requested_path#build/}"
      ;;
    *)
      release_die "Pages staging directory must be a child of $build_root: $requested_path"
      ;;
  esac

  case "$relative_path" in
    ""|/*|*/|*//* )
      release_die "Pages staging directory has an invalid relative path: $requested_path"
      ;;
  esac

  [[ ! -L "$build_root" ]] \
    || release_die "Pages build root must not be a symbolic link: $build_root"
  mkdir -p "$build_root"
  current_path="$build_root"
  IFS='/' read -r -a path_components <<< "$relative_path"
  for component in "${path_components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || release_die "Pages staging directory may not contain empty, dot or parent components: $requested_path"
    current_path="$current_path/$component"
    [[ ! -L "$current_path" ]] \
      || release_die "Pages staging directory may not traverse a symbolic link: $current_path"
  done

  candidate_path="$current_path"
  mkdir -p "$(dirname "$candidate_path")"

  current_path="$build_root"
  for component in "${path_components[@]}"; do
    current_path="$current_path/$component"
    [[ ! -L "$current_path" ]] \
      || release_die "Pages staging directory may not traverse a symbolic link: $current_path"
  done

  canonical_build_root="$(cd "$build_root" && pwd -P)"
  canonical_parent="$(cd "$(dirname "$candidate_path")" && pwd -P)"
  candidate_path="$canonical_parent/$(basename "$candidate_path")"
  case "$candidate_path" in
    "$canonical_build_root"/*) ;;
    *) release_die "Canonical Pages staging directory escaped $canonical_build_root: $candidate_path" ;;
  esac
  printf '%s' "$candidate_path"
}

SITE_DIRECTORY="$(canonicalize_site_directory "$SITE_DIRECTORY")"

if [[ -z "$SPARKLE_BIN" ]]; then
  SPARKLE_BIN="$($SCRIPT_DIR/download-sparkle-tools.sh | tail -n 1)"
fi
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[[ -x "$GENERATE_APPCAST" ]] || release_die "Sparkle generate_appcast is unavailable: $GENERATE_APPCAST"
[[ -x "$SIGN_UPDATE" ]] || release_die "Sparkle sign_update is unavailable: $SIGN_UPDATE"

PRIVATE_KEY=""
if [[ "$KEY_SOURCE" == "stdin" ]]; then
  IFS= read -r PRIVATE_KEY || true
  [[ -n "$PRIVATE_KEY" ]] || release_die "No Sparkle private key was provided on standard input."
fi

verify_sparkle_signature() {
  if [[ "$KEY_SOURCE" == "stdin" ]]; then
    printf '%s' "$PRIVATE_KEY" | "$SIGN_UPDATE" \
      --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
      --verify \
      --ed-key-file - \
      "$@"
  else
    "$SIGN_UPDATE" \
      --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
      --verify \
      "$@"
  fi
}

if [[ "$EXISTING_APPCAST_KIND" == "signed" ]]; then
  verify_sparkle_signature "$EXISTING_APPCAST" \
    || release_die "Production appcast failed Sparkle's cryptographic signed-feed verification."
  validate_canonical_appcast_items "$EXISTING_APPCAST"
  EXISTING_CHANNEL_XPATH="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']"
  EXISTING_ITEM_COUNT="$(xmllint --xpath "count($EXISTING_CHANNEL_XPATH/*[local-name()='item' and namespace-uri()=''])" "$EXISTING_APPCAST")"
  [[ "$EXISTING_ITEM_COUNT" =~ ^[1-9][0-9]*$ ]] \
    || release_die "A signed production appcast must contain at least one retained release."
  for ((index = 1; index <= EXISTING_ITEM_COUNT; index++)); do
    EXISTING_ITEM_XPATH="($EXISTING_CHANNEL_XPATH/*[local-name()='item' and namespace-uri()=''])[$index]"
    EXISTING_VERSION="$(xmllint --xpath "string($EXISTING_ITEM_XPATH/*[local-name()='shortVersionString' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$EXISTING_APPCAST")"
    EXISTING_BUILD="$(xmllint --xpath "string($EXISTING_ITEM_XPATH/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$EXISTING_APPCAST")"
    release_version_is_strictly_greater "$VERSION" "$EXISTING_VERSION" \
      || release_die "Release version $VERSION must be strictly greater than retained version $EXISTING_VERSION."
    release_decimal_is_strictly_greater "$BUILD_NUMBER" "$EXISTING_BUILD" \
      || release_die "Release build $BUILD_NUMBER must be strictly greater than retained build $EXISTING_BUILD."
  done
  release_log "Verified existing production appcast with Sparkle sign_update."
else
  [[ "$VERSION" == "0.1.0" && "$BUILD_NUMBER" == "1" ]] \
    || release_die "The unsigned seed is restricted to the initial 0.1.0 (build 1) release."
  validate_first_release_seed "$PROJECT_ROOT/updates/appcast.xml"
  validate_first_release_seed "$EXISTING_APPCAST"
  cmp "$EXISTING_APPCAST" "$PROJECT_ROOT/updates/appcast.xml" \
    || release_die "Unsigned first-release appcast is not byte-identical to the trusted repository seed."
  release_log "Accepted byte-identical seed only because fetch metadata recorded a production HTTP 404."
fi

WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/ushot-appcast.XXXXXX")"
cleanup() {
  rm -rf "$WORKSPACE"
}
trap cleanup EXIT

ARCHIVE_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.zip"
NOTES_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.md"
WORKSPACE_ARCHIVE="$WORKSPACE/$ARCHIVE_NAME"
WORKSPACE_NOTES="$WORKSPACE/$NOTES_NAME"
WORKSPACE_APPCAST="$WORKSPACE/appcast.xml"
ditto "$ARCHIVE_PATH" "$WORKSPACE_ARCHIVE"
ditto "$RELEASE_NOTES_SOURCE" "$WORKSPACE_NOTES"
ditto "$EXISTING_APPCAST" "$WORKSPACE_APPCAST"

GENERATE_ARGUMENTS=(
  --account "$USHOT_SPARKLE_KEY_ACCOUNT"
  --download-url-prefix "https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/$TAG/"
  --embed-release-notes
  --versions "$BUILD_NUMBER"
  --maximum-versions 5
  --maximum-deltas 0
  -o "$WORKSPACE_APPCAST"
)

if [[ "$KEY_SOURCE" == "stdin" ]]; then
  printf '%s' "$PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - "${GENERATE_ARGUMENTS[@]}" "$WORKSPACE"
else
  "$GENERATE_APPCAST" "${GENERATE_ARGUMENTS[@]}" "$WORKSPACE"
fi
validate_canonical_appcast_items "$WORKSPACE_APPCAST"

if [[ -e "$SITE_DIRECTORY" || -L "$SITE_DIRECTORY" ]]; then
  [[ -d "$SITE_DIRECTORY" && ! -L "$SITE_DIRECTORY" ]] \
    || release_die "Pages staging destination exists but is not a real directory: $SITE_DIRECTORY"
  rm -rf "$SITE_DIRECTORY"
fi
UPDATES_DIRECTORY="$SITE_DIRECTORY/updates"
mkdir -p "$UPDATES_DIRECTORY"

ditto "$WORKSPACE_APPCAST" "$UPDATES_DIRECTORY/appcast.xml"

"$SCRIPT_DIR/validate-appcast.sh" \
  --appcast "$UPDATES_DIRECTORY/appcast.xml" \
  --archive "$ARCHIVE_PATH" \
  --release-notes "$RELEASE_NOTES_SOURCE" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --tag "$TAG"

NEW_ENCLOSURE_SIGNATURE="$(xmllint --xpath "string((/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()=''])[1]/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='edSignature' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$UPDATES_DIRECTORY/appcast.xml")"
verify_sparkle_signature "$ARCHIVE_PATH" "$NEW_ENCLOSURE_SIGNATURE" \
  || release_die "Generated Sparkle enclosure signature failed cryptographic verification."
verify_sparkle_signature "$UPDATES_DIRECTORY/appcast.xml" \
  || release_die "Generated signed feed failed cryptographic verification."
unset PRIVATE_KEY

release_log "Signed Pages payload is ready: $SITE_DIRECTORY"
printf '%s\n' "$UPDATES_DIRECTORY/appcast.xml"
