#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

OUTPUT_PATH=""
KIND_OUTPUT_PATH=""
VERSION=""
BUILD_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_PATH="${2:?--output requires a value}"; shift 2 ;;
    --kind-output) KIND_OUTPUT_PATH="${2:?--kind-output requires a value}"; shift 2 ;;
    --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$OUTPUT_PATH" && -n "$KIND_OUTPUT_PATH" && -n "$VERSION" && -n "$BUILD_NUMBER" ]] \
  || release_die "usage: $0 --output /path/to/appcast.xml --kind-output /path/to/appcast.kind --version X.Y.Z --build-number N"
release_validate_feed_release_identity "$VERSION" "$BUILD_NUMBER"
SEED_APPCAST="$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH"
[[ -s "$SEED_APPCAST" ]] || release_die "Seed appcast is missing: $SEED_APPCAST"
release_require_command curl
release_require_command xmllint
mkdir -p "$(dirname "$OUTPUT_PATH")" "$(dirname "$KIND_OUTPUT_PATH")"

validate_first_release_seed() {
  local appcast_path="$1"

  xmllint --noout "$appcast_path"
  [[ "$(xmllint --xpath 'string(/*[local-name()="rss"]/@version)' "$appcast_path")" == "2.0" ]] \
    || release_die "First-release seed must be an RSS 2.0 document."
  [[ "$(xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"])' "$appcast_path")" == "1" ]] \
    || release_die "First-release seed must contain exactly one channel."
  [[ "$(xmllint --xpath 'count(//*[local-name()="item"])' "$appcast_path")" == "0" ]] \
    || release_die "First-release seed must not contain any update items."
  release_validate_canonical_appcast_channel "$appcast_path"
}

validate_first_release_seed "$SEED_APPCAST"

DOWNLOAD_PATH="$(mktemp "${TMPDIR:-/tmp}/ushot-current-appcast.XXXXXX")"
cleanup() {
  rm -f "$DOWNLOAD_PATH"
}
trap cleanup EXIT

HTTP_STATUS="$(curl --silent --show-error \
  --proto '=https' \
  --tlsv1.2 \
  --max-filesize "$USHOT_MAX_SIGNED_APPCAST_BYTES" \
  --user-agent 'UshotReleasePipeline/1' \
  --output "$DOWNLOAD_PATH" \
  --write-out '%{http_code}' \
  "$USHOT_APPCAST_URL")" || \
  release_die "Could not fetch the production appcast within the $USHOT_MAX_SIGNED_APPCAST_BYTES-byte limit."

case "$HTTP_STATUS" in
  200)
    [[ -s "$DOWNLOAD_PATH" ]] \
      || release_die "Production appcast returned HTTP 200 with an empty body."
    [[ "$(release_file_size "$DOWNLOAD_PATH")" -le "$USHOT_MAX_SIGNED_APPCAST_BYTES" ]] \
      || release_die "Production appcast exceeds the $USHOT_MAX_SIGNED_APPCAST_BYTES-byte limit."
    ditto "$DOWNLOAD_PATH" "$OUTPUT_PATH"
    printf 'signed' > "$KIND_OUTPUT_PATH"
    release_log "Fetched an opaque production appcast within the size limit; cryptographic verification is required before any XML parsing."
    ;;
  404)
    release_is_first_feed_identity "$VERSION" "$BUILD_NUMBER" \
      || release_die "Production appcast returned HTTP 404 for $VERSION (build $BUILD_NUMBER); only $USHOT_FIRST_FEED_VERSION (build $USHOT_FIRST_FEED_BUILD) may bootstrap from the zero-item seed. Refusing to reset signed history."
    ditto "$SEED_APPCAST" "$OUTPUT_PATH"
    cmp "$SEED_APPCAST" "$OUTPUT_PATH" \
      || release_die "Copied first-release seed differs from its trusted repository source."
    validate_first_release_seed "$OUTPUT_PATH"
    printf 'seed' > "$KIND_OUTPUT_PATH"
    release_log "Production appcast returned HTTP 404 for the exact first-feed identity $VERSION (build $BUILD_NUMBER); using the byte-identical repository seed."
    ;;
  *)
    release_die "Could not fetch the production appcast: HTTP $HTTP_STATUS"
    ;;
esac

printf '%s\n' "$OUTPUT_PATH"
