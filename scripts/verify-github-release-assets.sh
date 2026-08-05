#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

REPOSITORY=""
TAG=""
VERSION=""
BUILD_NUMBER=""
DIRECTORY=""
EXPECTED_STATE="draft"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) REPOSITORY="${2:?--repository requires a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
    --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    --directory) DIRECTORY="${2:?--directory requires a value}"; shift 2 ;;
    --expected-state) EXPECTED_STATE="${2:?--expected-state requires a value}"; shift 2 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ "$REPOSITORY" == "$USHOT_GITHUB_REPOSITORY" ]] \
  || release_die "GitHub repository must be $USHOT_GITHUB_REPOSITORY."
[[ "$EXPECTED_STATE" == "draft" || "$EXPECTED_STATE" == "published" || "$EXPECTED_STATE" == "either" ]] \
  || release_die "Expected Release state must be draft, published or either."
"$SCRIPT_DIR/validate-release-assets.sh" \
  --directory "$DIRECTORY" \
  --mode public-adhoc \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --tag "$TAG"
release_require_command gh
release_require_command jq

DMG_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dmg"
ZIP_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.zip"
DSYM_ZIP_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.dSYM.zip"
MANIFEST_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.release-manifest.json"
CHECKSUMS_NAME="SHA256SUMS.txt"
EXPECTED_NAMES=("$DMG_NAME" "$ZIP_NAME" "$DSYM_ZIP_NAME" "$MANIFEST_NAME" "$CHECKSUMS_NAME")

VERIFY_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/ushot-release.XXXXXX")"
RELEASE_JSON="$VERIFY_WORKSPACE/release.json"
RELEASE_LIST_JSON="$VERIFY_WORKSPACE/releases.json"
REMOTE_DOWNLOAD_DIR="$VERIFY_WORKSPACE/downloads"
mkdir -p "$REMOTE_DOWNLOAD_DIR"
cleanup() {
  rm -rf "$VERIFY_WORKSPACE"
}
trap cleanup EXIT
gh api --paginate --slurp \
  "repos/$REPOSITORY/releases?per_page=100" \
  > "$RELEASE_LIST_JSON"
RELEASE_COUNT="$(jq -r \
  --arg tag "$TAG" \
  '[.[][] | select(.tag_name == $tag)] | length' \
  "$RELEASE_LIST_JSON")"
[[ "$RELEASE_COUNT" == "1" ]] \
  || release_die "Expected exactly one GitHub Release for $TAG, found $RELEASE_COUNT."
jq \
  --arg tag "$TAG" \
  '.[][] | select(.tag_name == $tag)' \
  "$RELEASE_LIST_JSON" \
  > "$RELEASE_JSON"

[[ "$(jq -r '.tag_name' "$RELEASE_JSON")" == "$TAG" ]] \
  || release_die "GitHub Release tag does not match $TAG."
[[ "$(jq -r '.prerelease' "$RELEASE_JSON")" == "false" ]] \
  || release_die "Stable Ushot assets may not be attached to a prerelease."
ACTUAL_STATE="published"
if [[ "$(jq -r '.draft' "$RELEASE_JSON")" == "true" ]]; then
  ACTUAL_STATE="draft"
fi
if [[ "$EXPECTED_STATE" != "either" && "$ACTUAL_STATE" != "$EXPECTED_STATE" ]]; then
  release_die "GitHub Release state is $ACTUAL_STATE; expected $EXPECTED_STATE."
fi

EXPECTED_SORTED="$(printf '%s\n' "${EXPECTED_NAMES[@]}" | sort)"
ACTUAL_SORTED="$(jq -r '.assets[].name' "$RELEASE_JSON" | sort)"
[[ "$ACTUAL_SORTED" == "$EXPECTED_SORTED" ]] \
  || release_die "GitHub Release assets differ from the exact expected set."

for name in "${EXPECTED_NAMES[@]}"; do
  LOCAL_SIZE="$(release_file_size "$DIRECTORY/$name")"
  LOCAL_SHA="$(release_sha256 "$DIRECTORY/$name")"
  REMOTE_SIZE="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | .size' "$RELEASE_JSON")"
  REMOTE_ID="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | .id' "$RELEASE_JSON")"
  REMOTE_STATE="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | (.state // "")' "$RELEASE_JSON")"
  REMOTE_DIGEST="$(jq -r --arg name "$name" '.assets[] | select(.name == $name) | (.digest // "")' "$RELEASE_JSON")"
  [[ "$REMOTE_SIZE" == "$LOCAL_SIZE" ]] \
    || release_die "Uploaded size mismatch for $name: local=$LOCAL_SIZE remote=$REMOTE_SIZE"
  [[ -z "$REMOTE_STATE" || "$REMOTE_STATE" == "uploaded" ]] \
    || release_die "GitHub asset is not fully uploaded: $name ($REMOTE_STATE)"
  if [[ -n "$REMOTE_DIGEST" ]]; then
    [[ "$REMOTE_DIGEST" == "sha256:$LOCAL_SHA" ]] \
      || release_die "GitHub asset digest mismatch for $name."
  else
    release_warn "GitHub did not expose a digest for $name; downloading the remote asset for SHA-256 verification."
    [[ "$REMOTE_ID" =~ ^[1-9][0-9]*$ ]] \
      || release_die "GitHub asset has an invalid API identifier: $name"
    gh api \
      --header 'Accept: application/octet-stream' \
      "repos/$REPOSITORY/releases/assets/$REMOTE_ID" \
      > "$REMOTE_DOWNLOAD_DIR/$name"
    [[ -f "$REMOTE_DOWNLOAD_DIR/$name" ]] \
      || release_die "GitHub asset download did not produce the expected file: $name"
    [[ "$(release_file_size "$REMOTE_DOWNLOAD_DIR/$name")" == "$LOCAL_SIZE" ]] \
      || release_die "Downloaded GitHub asset size mismatch for $name."
    [[ "$(release_sha256 "$REMOTE_DOWNLOAD_DIR/$name")" == "$LOCAL_SHA" ]] \
      || release_die "Downloaded GitHub asset digest mismatch for $name."
  fi
done

release_log "GitHub $ACTUAL_STATE Release contains the exact verified asset set for $TAG."
