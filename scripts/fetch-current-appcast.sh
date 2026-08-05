#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

OUTPUT_PATH=""
KIND_OUTPUT_PATH=""
ALLOW_FIRST_RELEASE_SEED="NO"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_PATH="${2:?--output requires a value}"; shift 2 ;;
    --kind-output) KIND_OUTPUT_PATH="${2:?--kind-output requires a value}"; shift 2 ;;
    --allow-first-release-seed) ALLOW_FIRST_RELEASE_SEED="${2:?--allow-first-release-seed requires a value}"; shift 2 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$OUTPUT_PATH" && -n "$KIND_OUTPUT_PATH" ]] \
  || release_die "usage: $0 --output /path/to/appcast.xml --kind-output /path/to/appcast.kind [--allow-first-release-seed YES]"
[[ "$ALLOW_FIRST_RELEASE_SEED" == "YES" || "$ALLOW_FIRST_RELEASE_SEED" == "NO" ]] \
  || release_die "--allow-first-release-seed must be YES or NO."
SEED_APPCAST="$PROJECT_ROOT/updates/appcast.xml"
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
  [[ "$(xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="title"])' "$appcast_path")" == "1" \
      && "$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="title"])' "$appcast_path")" == "Ushot Updates" ]] \
    || release_die "First-release seed has an unexpected channel title."
  [[ "$(xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="link"])' "$appcast_path")" == "1" \
      && "$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="link"])' "$appcast_path")" == "$USHOT_APPCAST_URL" ]] \
    || release_die "First-release seed has an unexpected channel link."
  [[ "$(xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="description"])' "$appcast_path")" == "1" \
      && "$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="description"])' "$appcast_path")" == "Stable Ushot updates for macOS." ]] \
    || release_die "First-release seed has an unexpected channel description."
  [[ "$(xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="language"])' "$appcast_path")" == "1" \
      && "$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="language"])' "$appcast_path")" == "en" ]] \
    || release_die "First-release seed has an unexpected channel language."
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
  --user-agent 'UshotReleasePipeline/1' \
  --output "$DOWNLOAD_PATH" \
  --write-out '%{http_code}' \
  "$USHOT_APPCAST_URL")"

case "$HTTP_STATUS" in
  200)
    xmllint --noout "$DOWNLOAD_PATH"
    ditto "$DOWNLOAD_PATH" "$OUTPUT_PATH"
    printf 'signed' > "$KIND_OUTPUT_PATH"
    release_log "Fetched production appcast; cryptographic verification is required before regeneration."
    ;;
  404)
    [[ "$ALLOW_FIRST_RELEASE_SEED" == "YES" ]] \
      || release_die "Production appcast returned HTTP 404 after the first-release seed window; refusing to reset signed history."
    ditto "$SEED_APPCAST" "$OUTPUT_PATH"
    cmp "$SEED_APPCAST" "$OUTPUT_PATH" \
      || release_die "Copied first-release seed differs from its trusted repository source."
    validate_first_release_seed "$OUTPUT_PATH"
    printf 'seed' > "$KIND_OUTPUT_PATH"
    release_log "Production appcast returned HTTP 404; using the byte-identical repository seed."
    ;;
  *)
    release_die "Could not fetch the production appcast: HTTP $HTTP_STATUS"
    ;;
esac

printf '%s\n' "$OUTPUT_PATH"
