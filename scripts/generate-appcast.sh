#!/bin/bash
set -euo pipefail
set +x
ulimit -c 0
unset SPARKLE_ED25519_PRIVATE_KEY SPARKLE_PRIVATE_KEY PRIVATE_KEY

# When a private key is supplied on standard input, capture it with shell
# builtins before any external command can inherit that descriptor. Scan only
# the key-source option here; the authoritative argument parser still runs
# below after the input descriptor has been closed.
PREFLIGHT_KEY_SOURCE="keychain"
PREFLIGHT_KEY_SOURCE_COUNT=0
PREFLIGHT_HELP_REQUESTED=false
PREFLIGHT_ARGUMENTS=("$@")
for ((argument_index = 0; argument_index < ${#PREFLIGHT_ARGUMENTS[@]}; )); do
  case "${PREFLIGHT_ARGUMENTS[$argument_index]}" in
    --key-source)
      if ((argument_index + 1 >= ${#PREFLIGHT_ARGUMENTS[@]})); then
        printf '%s\n' 'error: --key-source requires a value' >&2
        exit 1
      fi
      PREFLIGHT_KEY_SOURCE="${PREFLIGHT_ARGUMENTS[$((argument_index + 1))]}"
      PREFLIGHT_KEY_SOURCE_COUNT=$((PREFLIGHT_KEY_SOURCE_COUNT + 1))
      argument_index=$((argument_index + 2))
      ;;
    --help|-h)
      PREFLIGHT_HELP_REQUESTED=true
      argument_index=$((argument_index + 1))
      ;;
    *)
      argument_index=$((argument_index + 1))
      ;;
  esac
done
if ((PREFLIGHT_KEY_SOURCE_COUNT > 1)); then
  printf '%s\n' 'error: --key-source may be specified only once' >&2
  exit 1
fi
if [[ "$PREFLIGHT_KEY_SOURCE" != "keychain" && "$PREFLIGHT_KEY_SOURCE" != "stdin" ]]; then
  printf '%s\n' 'error: --key-source must be keychain or stdin' >&2
  exit 1
fi
PRIVATE_KEY=""
if [[ "$PREFLIGHT_HELP_REQUESTED" != "true" && "$PREFLIGHT_KEY_SOURCE" == "stdin" ]]; then
  IFS= read -r PRIVATE_KEY || true
  exec </dev/null
  if [[ -z "$PRIVATE_KEY" ]]; then
    printf '%s\n' 'error: no Sparkle private key was provided on standard input' >&2
    exit 1
  fi
fi

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
SIGNING_BOUNDARY_OUTPUT_ONLY=false
AUTHENTICATED_APPCAST_VALIDATOR=""
AUTHENTICATED_APPCAST_VALIDATOR_SHA256=""
PUBLIC_KEY_DERIVER=""
PUBLIC_KEY_DERIVER_SHA256=""
WORKSPACE=""
DERIVED_PUBLIC_KEY=""

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  unset PRIVATE_KEY DERIVED_PUBLIC_KEY
  if [[ -n "${WORKSPACE:-}" && -d "$WORKSPACE" && ! -L "$WORKSPACE" ]]; then
    rm -rf -- "$WORKSPACE"
  fi
  return "$status"
}
trap cleanup EXIT
signal_exit() {
  local status="$1"
  trap - HUP INT TERM
  exit "$status"
}
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

usage() {
  printf '%s\n' "usage: $0 --version X.Y.Z --build-number N --tag vX.Y.Z --archive PATH --release-notes PATH --existing-appcast PATH --existing-appcast-kind signed|seed [--site-directory PATH] [--sparkle-bin PATH] [--key-source keychain|stdin] [--public-key-deriver ABSOLUTE_PATH --public-key-deriver-sha256 SHA256] [--authenticated-appcast-validator ABSOLUTE_PATH --authenticated-appcast-validator-sha256 SHA256] [--signing-boundary-output-only]"
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
    --authenticated-appcast-validator)
      [[ -z "$AUTHENTICATED_APPCAST_VALIDATOR" ]] \
        || release_die "--authenticated-appcast-validator may be specified only once."
      AUTHENTICATED_APPCAST_VALIDATOR="${2:?--authenticated-appcast-validator requires a value}"
      shift 2
      ;;
    --authenticated-appcast-validator-sha256)
      [[ -z "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" ]] \
        || release_die "--authenticated-appcast-validator-sha256 may be specified only once."
      AUTHENTICATED_APPCAST_VALIDATOR_SHA256="${2:?--authenticated-appcast-validator-sha256 requires a value}"
      shift 2
      ;;
    --public-key-deriver)
      [[ -z "$PUBLIC_KEY_DERIVER" ]] \
        || release_die "--public-key-deriver may be specified only once."
      PUBLIC_KEY_DERIVER="${2:?--public-key-deriver requires a value}"
      shift 2
      ;;
    --public-key-deriver-sha256)
      [[ -z "$PUBLIC_KEY_DERIVER_SHA256" ]] \
        || release_die "--public-key-deriver-sha256 may be specified only once."
      PUBLIC_KEY_DERIVER_SHA256="${2:?--public-key-deriver-sha256 requires a value}"
      shift 2
      ;;
    --signing-boundary-output-only)
      [[ "$SIGNING_BOUNDARY_OUTPUT_ONLY" == "false" ]] \
        || release_die "--signing-boundary-output-only may be specified only once."
      SIGNING_BOUNDARY_OUTPUT_ONLY=true
      shift
      ;;
    --help|-h) usage; exit 0 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$VERSION" && -n "$BUILD_NUMBER" && -n "$TAG" && -n "$ARCHIVE_PATH" && -n "$RELEASE_NOTES_SOURCE" && -n "$EXISTING_APPCAST" && -n "$EXISTING_APPCAST_KIND" ]] \
  || { usage >&2; exit 1; }
[[ "$KEY_SOURCE" == "keychain" || "$KEY_SOURCE" == "stdin" ]] \
  || release_die "--key-source must be keychain or stdin."
[[ "$KEY_SOURCE" == "$PREFLIGHT_KEY_SOURCE" ]] \
  || release_die "Key-source preflight disagreed with parsed arguments."
[[ "$SIGNING_BOUNDARY_OUTPUT_ONLY" != "true" || "$KEY_SOURCE" == "stdin" ]] \
  || release_die "--signing-boundary-output-only requires --key-source stdin."
if [[ -n "$AUTHENTICATED_APPCAST_VALIDATOR" \
      && -z "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" ]] \
    || [[ -z "$AUTHENTICATED_APPCAST_VALIDATOR" \
      && -n "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" ]]; then
  release_die "--authenticated-appcast-validator and --authenticated-appcast-validator-sha256 must be supplied together."
fi
[[ "$SIGNING_BOUNDARY_OUTPUT_ONLY" != "true" || -n "$AUTHENTICATED_APPCAST_VALIDATOR" ]] \
  || release_die "--signing-boundary-output-only requires a reviewed authenticated-appcast validator."
if [[ -n "$PUBLIC_KEY_DERIVER" \
      && -z "$PUBLIC_KEY_DERIVER_SHA256" ]] \
    || [[ -z "$PUBLIC_KEY_DERIVER" \
      && -n "$PUBLIC_KEY_DERIVER_SHA256" ]]; then
  release_die "--public-key-deriver and --public-key-deriver-sha256 must be supplied together."
fi
[[ "$SIGNING_BOUNDARY_OUTPUT_ONLY" != "true" || -n "$PUBLIC_KEY_DERIVER" ]] \
  || release_die "--signing-boundary-output-only requires a reviewed public-key deriver."
unset PREFLIGHT_ARGUMENTS PREFLIGHT_HELP_REQUESTED \
  PREFLIGHT_KEY_SOURCE PREFLIGHT_KEY_SOURCE_COUNT
[[ "$EXISTING_APPCAST_KIND" == "signed" || "$EXISTING_APPCAST_KIND" == "seed" ]] \
  || release_die "--existing-appcast-kind must be signed or seed."

if [[ -n "$PUBLIC_KEY_DERIVER" ]]; then
  case "$PUBLIC_KEY_DERIVER" in
    /*) ;;
    *) release_die "Public-key deriver path must be absolute." ;;
  esac
  [[ "$PUBLIC_KEY_DERIVER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Public-key deriver SHA-256 must be 64 lowercase hexadecimal characters."
  [[ -f "$PUBLIC_KEY_DERIVER" \
      && ! -L "$PUBLIC_KEY_DERIVER" \
      && -x "$PUBLIC_KEY_DERIVER" ]] \
    || release_die "Public-key deriver must be an executable regular non-symbolic file: $PUBLIC_KEY_DERIVER"
  PUBLIC_KEY_DERIVER="$({
    cd "$(dirname "$PUBLIC_KEY_DERIVER")" && \
      printf '%s/%s' "$(pwd -P)" "$(basename "$PUBLIC_KEY_DERIVER")"
  })"
  if [[ "$SIGNING_BOUNDARY_OUTPUT_ONLY" == "true" ]]; then
    [[ "$(basename "$PUBLIC_KEY_DERIVER")" == "SparklePublicKeyDeriver" ]] \
      || release_die "Signing-boundary public-key deriver must be the reviewed SparklePublicKeyDeriver executable, not a Swift runtime or compiler."
  fi
  [[ "$(release_sha256 "$PUBLIC_KEY_DERIVER")" == "$PUBLIC_KEY_DERIVER_SHA256" ]] \
    || release_die "Public-key deriver checksum does not match the reviewed executable."
fi

if [[ "$KEY_SOURCE" == "stdin" ]]; then
  if [[ -n "$PUBLIC_KEY_DERIVER" ]]; then
    [[ -f "$PUBLIC_KEY_DERIVER" \
        && ! -L "$PUBLIC_KEY_DERIVER" \
        && -x "$PUBLIC_KEY_DERIVER" \
        && "$(release_sha256 "$PUBLIC_KEY_DERIVER")" == "$PUBLIC_KEY_DERIVER_SHA256" ]] \
      || release_die "Reviewed public-key deriver changed before execution."
    DERIVED_PUBLIC_KEY="$(
      printf '%s' "$PRIVATE_KEY" | "$PUBLIC_KEY_DERIVER"
    )" || release_die "Sparkle private key failed canonical seed validation."
  else
    [[ -x /usr/bin/swift ]] \
      || release_die "System Swift runtime is unavailable for private-key validation."
    DERIVED_PUBLIC_KEY="$(
      printf '%s' "$PRIVATE_KEY" | \
        /usr/bin/swift "$SCRIPT_DIR/derive-sparkle-public-key.swift"
    )" || release_die "Sparkle private key failed canonical seed validation."
  fi
  [[ -n "$DERIVED_PUBLIC_KEY" ]] \
    || release_die "Sparkle private key validation returned no public key."
  unset DERIVED_PUBLIC_KEY
fi
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_tag "$TAG" "$VERSION"
release_validate_feed_release_identity "$VERSION" "$BUILD_NUMBER"
[[ -s "$ARCHIVE_PATH" ]] || release_die "Sparkle ZIP is missing or empty: $ARCHIVE_PATH"
[[ "$(basename "$ARCHIVE_PATH")" == "$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.zip" ]] \
  || release_die "Unexpected Sparkle ZIP filename: $(basename "$ARCHIVE_PATH")"
release_validate_release_notes_source "$RELEASE_NOTES_SOURCE"
[[ -s "$EXISTING_APPCAST" ]] || release_die "Existing or seed appcast is missing: $EXISTING_APPCAST"
release_require_command xmllint

if [[ -n "$AUTHENTICATED_APPCAST_VALIDATOR" ]]; then
  case "$AUTHENTICATED_APPCAST_VALIDATOR" in
    /*) ;;
    *) release_die "Authenticated-appcast validator path must be absolute." ;;
  esac
  [[ "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Authenticated-appcast validator SHA-256 must be 64 lowercase hexadecimal characters."
  [[ -f "$AUTHENTICATED_APPCAST_VALIDATOR" \
      && ! -L "$AUTHENTICATED_APPCAST_VALIDATOR" \
      && -x "$AUTHENTICATED_APPCAST_VALIDATOR" ]] \
    || release_die "Authenticated-appcast validator must be an executable regular non-symbolic file: $AUTHENTICATED_APPCAST_VALIDATOR"
  AUTHENTICATED_APPCAST_VALIDATOR="$({
    cd "$(dirname "$AUTHENTICATED_APPCAST_VALIDATOR")" && \
      printf '%s/%s' "$(pwd -P)" "$(basename "$AUTHENTICATED_APPCAST_VALIDATOR")"
  })"
  [[ "$(release_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR")" == "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" ]] \
    || release_die "Authenticated-appcast validator checksum does not match the reviewed executable."
fi

validate_authenticated_signed_appcast() {
  local appcast_path="$1"

  if [[ -n "$AUTHENTICATED_APPCAST_VALIDATOR" ]]; then
    [[ -f "$AUTHENTICATED_APPCAST_VALIDATOR" \
        && ! -L "$AUTHENTICATED_APPCAST_VALIDATOR" \
        && -x "$AUTHENTICATED_APPCAST_VALIDATOR" \
        && "$(release_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR")" == "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" ]] \
      || release_die "Reviewed authenticated-appcast validator changed before execution."
    "$AUTHENTICATED_APPCAST_VALIDATOR" "$appcast_path" \
      || release_die "Cryptographically verified appcast failed the reviewed authenticated XML policy."
  else
    release_validate_authenticated_appcast_runtime_policy "$appcast_path"
  fi
}

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
  release_validate_canonical_appcast_channel "$appcast_path"
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
  release_validate_canonical_appcast_channel "$appcast_path"
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
    [[ "$(xmllint --xpath "count($item_xpath/*[local-name()='enclosure']/@*[local-name()='version' or local-name()='shortVersionString'])" "$appcast_path")" == "0" ]] \
      || release_die "Appcast item $index must express version identity only in canonical Sparkle child elements."
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

if [[ -z "$SPARKLE_BIN" && "$KEY_SOURCE" == "stdin" ]]; then
  release_die "--sparkle-bin must identify freshly verified tools when the private key is supplied on stdin."
fi
if [[ -z "$SPARKLE_BIN" ]]; then
  SPARKLE_BIN="$($SCRIPT_DIR/download-sparkle-tools.sh | tail -n 1)"
fi
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[[ -x "$GENERATE_APPCAST" ]] || release_die "Sparkle generate_appcast is unavailable: $GENERATE_APPCAST"
[[ -x "$SIGN_UPDATE" ]] || release_die "Sparkle sign_update is unavailable: $SIGN_UPDATE"

if [[ "$KEY_SOURCE" == "stdin" ]]; then
  [[ -n "$PRIVATE_KEY" ]] || release_die "No Sparkle private key was provided on standard input."
  export -n PRIVATE_KEY
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
  validate_authenticated_signed_appcast "$EXISTING_APPCAST"
  xmllint --noout "$EXISTING_APPCAST" \
    || release_die "Authenticated production appcast is not well-formed XML."
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
  release_is_first_feed_identity "$VERSION" "$BUILD_NUMBER" \
    || release_die "The unsigned seed is restricted to the exact first-feed identity $USHOT_FIRST_FEED_VERSION (build $USHOT_FIRST_FEED_BUILD); got $VERSION (build $BUILD_NUMBER)."
  validate_first_release_seed "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH"
  validate_first_release_seed "$EXISTING_APPCAST"
  cmp "$EXISTING_APPCAST" "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
    || release_die "Unsigned first-release appcast is not byte-identical to the trusted repository seed."
  release_log "Accepted byte-identical seed only because fetch metadata recorded a production HTTP 404."
fi

WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/ushot-appcast.XXXXXX")"

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
verify_sparkle_signature "$WORKSPACE_APPCAST" \
  || release_die "Generated signed feed failed cryptographic verification before XML parsing."
validate_authenticated_signed_appcast "$WORKSPACE_APPCAST"
xmllint --noout "$WORKSPACE_APPCAST" \
  || release_die "Generated authenticated appcast is not well-formed XML."
validate_canonical_appcast_items "$WORKSPACE_APPCAST"
NEW_ENCLOSURE_SIGNATURE="$(xmllint --xpath "string((/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()=''])[1]/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='edSignature' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$WORKSPACE_APPCAST")"
verify_sparkle_signature "$ARCHIVE_PATH" "$NEW_ENCLOSURE_SIGNATURE" \
  || release_die "Generated Sparkle enclosure signature failed cryptographic verification."
unset PRIVATE_KEY DERIVED_PUBLIC_KEY

stage_signed_pages_payload() {
  if [[ -e "$SITE_DIRECTORY" || -L "$SITE_DIRECTORY" ]]; then
    [[ -d "$SITE_DIRECTORY" && ! -L "$SITE_DIRECTORY" ]] \
      || release_die "Pages staging destination exists but is not a real directory: $SITE_DIRECTORY"
    rm -rf "$SITE_DIRECTORY"
  fi
  SITE_APPCAST="$SITE_DIRECTORY/$USHOT_APPCAST_RELATIVE_PATH"
  mkdir -p "$(dirname "$SITE_APPCAST")"

  ditto "$WORKSPACE_APPCAST" "$SITE_APPCAST"
  cmp "$WORKSPACE_APPCAST" "$SITE_APPCAST" \
    || release_die "Signed Pages appcast changed while entering the publication staging directory."
}

if [[ "$SIGNING_BOUNDARY_OUTPUT_ONLY" == "true" ]]; then
  # The protected signing runner preserves these already authenticated bytes
  # immediately after the checksum-bound validator and fixed shell gates. A
  # separate credential-free job validates the immutable artifact again before
  # deployment.
  stage_signed_pages_payload
  release_log "Signed Pages payload is ready for immutable preservation: $SITE_DIRECTORY"
else
  stage_signed_pages_payload
  "$SCRIPT_DIR/validate-appcast.sh" \
    --appcast "$SITE_APPCAST" \
    --archive "$ARCHIVE_PATH" \
    --release-notes "$RELEASE_NOTES_SOURCE" \
    --version "$VERSION" \
    --build-number "$BUILD_NUMBER" \
    --tag "$TAG"

  release_log "Signed Pages payload is ready: $SITE_DIRECTORY"
fi

printf '%s\n' "$SITE_APPCAST"
