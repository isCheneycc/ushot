#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

TAG=""
BUILD_NUMBER=""
REPOSITORY="${GITHUB_REPOSITORY:-$USHOT_GITHUB_REPOSITORY}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    --repository) REPOSITORY="${2:?--repository requires a value}"; shift 2 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$TAG" && -n "$BUILD_NUMBER" ]] \
  || release_die "usage: $0 --tag vX.Y.Z --build-number N [--repository owner/repo]"
[[ "$TAG" == v* ]] || release_die "Release tag must begin with v: $TAG"
VERSION="${TAG#v}"
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_tag "$TAG" "$VERSION"
[[ "$REPOSITORY" == "$USHOT_GITHUB_REPOSITORY" ]] \
  || release_die "Release repository must be $USHOT_GITHUB_REPOSITORY, got $REPOSITORY"
release_validate_source_settings "$PROJECT_ROOT" "$VERSION" "$BUILD_NUMBER"

TAG_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" \
  || release_die "Tag does not exist in this checkout: $TAG"
HEAD_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
[[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] \
  || release_die "Checked-out commit $HEAD_COMMIT does not match $TAG ($TAG_COMMIT)."
git -C "$PROJECT_ROOT" diff --quiet \
  || release_die "Tracked working tree changes are forbidden during release."
git -C "$PROJECT_ROOT" diff --cached --quiet \
  || release_die "Staged working tree changes are forbidden during release."
[[ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]] \
  || release_die "Untracked or modified files are forbidden during release."

NOTES_PATH="$PROJECT_ROOT/updates/release-notes/$VERSION.md"
[[ -s "$NOTES_PATH" ]] || release_die "Committed release notes are required: $NOTES_PATH"
release_validate_release_notes_source "$NOTES_PATH"
if grep -Eq 'sparkle-sign-warning:|sparkle-signatures:' "$NOTES_PATH"; then
  release_die "Source release notes must be unsigned before embedding in the signed appcast."
fi

for script in "$PROJECT_ROOT"/scripts/*.sh; do
  bash -n "$script"
done
xmllint --noout "$PROJECT_ROOT/updates/appcast.xml"
release_log "Release preflight passed: repository=$REPOSITORY tag=$TAG build=$BUILD_NUMBER commit=$HEAD_COMMIT"
printf 'VERSION=%s\nBUILD_NUMBER=%s\nTAG=%s\n' "$VERSION" "$BUILD_NUMBER" "$TAG"
