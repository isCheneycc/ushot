#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

APPCAST_PATH=""
ARCHIVE_PATH=""
RELEASE_NOTES_PATH=""
VERSION=""
BUILD_NUMBER=""
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appcast) APPCAST_PATH="${2:?--appcast requires a value}"; shift 2 ;;
    --archive) ARCHIVE_PATH="${2:?--archive requires a value}"; shift 2 ;;
    --release-notes) RELEASE_NOTES_PATH="${2:?--release-notes requires a value}"; shift 2 ;;
    --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?--build-number requires a value}"; shift 2 ;;
    --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -s "$APPCAST_PATH" ]] || release_die "Appcast is missing or empty: $APPCAST_PATH"
[[ -s "$ARCHIVE_PATH" ]] || release_die "Sparkle archive is missing or empty: $ARCHIVE_PATH"
[[ -s "$RELEASE_NOTES_PATH" ]] || release_die "Release-notes source is missing or empty: $RELEASE_NOTES_PATH"
release_validate_version "$VERSION"
release_validate_build_number "$BUILD_NUMBER"
release_validate_tag "$TAG" "$VERSION"
release_validate_release_notes_source "$RELEASE_NOTES_PATH"
release_require_command xmllint
xmllint --noout "$APPCAST_PATH"

CHANNEL_XPATH="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']"
[[ "$(xmllint --xpath "count(/*[local-name()='rss' and namespace-uri()=''])" "$APPCAST_PATH")" == "1" \
    && "$(xmllint --xpath "string(/*[local-name()='rss' and namespace-uri()='']/@version)" "$APPCAST_PATH")" == "2.0" ]] \
  || release_die "Appcast must be an RSS 2.0 document in the empty XML namespace."
[[ "$(xmllint --xpath "count($CHANNEL_XPATH)" "$APPCAST_PATH")" == "1" \
    && "$(xmllint --xpath "count(//*[local-name()='channel'])" "$APPCAST_PATH")" == "1" ]] \
  || release_die "Appcast must contain exactly one canonical RSS channel."

[[ "$(xmllint --xpath "count(//*[local-name()='item']/*[local-name()='link'])" "$APPCAST_PATH")" == "0" ]] \
  || release_die "Appcast items must not contain informational links."
[[ "$(xmllint --xpath "count(//*[local-name()='item']/*[local-name()='fullReleaseNotesLink'])" "$APPCAST_PATH")" == "0" ]] \
  || release_die "Appcast items must not contain unsigned full-release-notes links."
[[ "$(xmllint --xpath "count(//*[local-name()='item']/*[local-name()='releaseNotesLink'])" "$APPCAST_PATH")" == "0" ]] \
  || release_die "Appcast items must not contain detached release notes."
[[ "$(xmllint --xpath "count(//*[local-name()='item']/*[local-name()='deltas'])" "$APPCAST_PATH")" == "0" ]] \
  || release_die "Appcast items must not contain delta updates."
[[ "$(xmllint --xpath "count(//*[local-name()='item']/*[local-name()='enclosure']/@*[local-name()='deltaFrom' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle'])" "$APPCAST_PATH")" == "0" ]] \
  || release_die "Appcast items must not be delta child updates."

ITEM_COUNT="$(xmllint --xpath "count($CHANNEL_XPATH/*[local-name()='item' and namespace-uri()=''])" "$APPCAST_PATH")"
[[ "$ITEM_COUNT" =~ ^[1-9][0-9]*$ ]] || release_die "Appcast must contain at least one update item."
[[ "$(xmllint --xpath "count(//*[local-name()='item'])" "$APPCAST_PATH")" == "$ITEM_COUNT" ]] \
  || release_die "Appcast contains an item outside the canonical RSS channel or XML namespace."
for ((index = 1; index <= ITEM_COUNT; index++)); do
  ITEM_XPATH="($CHANNEL_XPATH/*[local-name()='item' and namespace-uri()=''])[$index]"
  [[ "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")" == "1" \
      && "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='version'])" "$APPCAST_PATH")" == "1" ]] \
    || release_die "Appcast item $index must contain exactly one build version."
  [[ "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='shortVersionString' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")" == "1" \
      && "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='shortVersionString'])" "$APPCAST_PATH")" == "1" ]] \
    || release_die "Appcast item $index must contain exactly one semantic version."
  [[ "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()=''])" "$APPCAST_PATH")" == "1" \
      && "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='enclosure'])" "$APPCAST_PATH")" == "1" ]] \
    || release_die "Appcast item $index must contain exactly one enclosure."
  [[ "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='informationalUpdate'])" "$APPCAST_PATH")" == "0" ]] \
    || release_die "Appcast item $index must not be an informational-only update."
  [[ "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='minimumAutoupdateVersion'])" "$APPCAST_PATH")" == "0" ]] \
    || release_die "Appcast item $index must not be a major upgrade."
  [[ "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='description' and namespace-uri()=''])" "$APPCAST_PATH")" == "1" \
      && "$(xmllint --xpath "count($ITEM_XPATH/*[local-name()='description'])" "$APPCAST_PATH")" == "1" ]] \
    || release_die "Appcast item $index must contain exactly one embedded release-notes description."
  [[ -n "$(xmllint --xpath "normalize-space(string($ITEM_XPATH/*[local-name()='description' and namespace-uri()='']))" "$APPCAST_PATH")" ]] \
    || release_die "Appcast item $index has empty embedded release notes."
  [[ "$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='description' and namespace-uri()='']/@*[local-name()='format' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")" == "markdown" ]] \
    || release_die "Appcast item $index must use embedded Markdown release notes."
  ITEM_NOTES="$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='description' and namespace-uri()=''])" "$APPCAST_PATH")"
  release_validate_release_notes_content "$ITEM_NOTES"

  ITEM_VERSION="$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='shortVersionString' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")"
  ITEM_BUILD="$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")"
  ITEM_ENCLOSURE_URL="$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@url)" "$APPCAST_PATH")"
  ITEM_INSTALLATION_TYPE="$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='installationType' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")"
  release_validate_version "$ITEM_VERSION"
  release_validate_build_number "$ITEM_BUILD"
  [[ "$ITEM_ENCLOSURE_URL" == "https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/v$ITEM_VERSION/$USHOT_PRODUCT_NAME-$ITEM_VERSION-$USHOT_ARCHITECTURE.zip" ]] \
    || release_die "Appcast item $index has a noncanonical enclosure URL: $ITEM_ENCLOSURE_URL"
  [[ -z "$ITEM_INSTALLATION_TYPE" || "$ITEM_INSTALLATION_TYPE" == "application" ]] \
    || release_die "Appcast item $index must use the application installation type."
  [[ "$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@type)" "$APPCAST_PATH")" == "application/octet-stream" ]] \
    || release_die "Appcast item $index must use an application archive enclosure."
  [[ -n "$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@length)" "$APPCAST_PATH")" ]] \
    || release_die "Appcast item $index must declare its archive length."
  [[ -n "$(xmllint --xpath "string($ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='edSignature' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")" ]] \
    || release_die "Appcast item $index must carry an EdDSA archive signature."
done

FIRST_ITEM_XPATH="($CHANNEL_XPATH/*[local-name()='item' and namespace-uri()=''])[1]"
FIRST_ITEM_VERSION="$(xmllint --xpath "string($FIRST_ITEM_XPATH/*[local-name()='version' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")"
FIRST_ITEM_SHORT_VERSION="$(xmllint --xpath "string($FIRST_ITEM_XPATH/*[local-name()='shortVersionString' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")"
ENCLOSURE_URL="$(xmllint --xpath "string($FIRST_ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@url)" "$APPCAST_PATH")"
ENCLOSURE_LENGTH="$(xmllint --xpath "string($FIRST_ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@length)" "$APPCAST_PATH")"
ENCLOSURE_SIGNATURE="$(xmllint --xpath "string($FIRST_ITEM_XPATH/*[local-name()='enclosure' and namespace-uri()='']/@*[local-name()='edSignature' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$APPCAST_PATH")"
EMBEDDED_NOTES="$(xmllint --xpath "string($FIRST_ITEM_XPATH/*[local-name()='description' and namespace-uri()=''])" "$APPCAST_PATH")"
EXPECTED_NOTES="$(<"$RELEASE_NOTES_PATH")"

EXPECTED_ARCHIVE_NAME="$USHOT_PRODUCT_NAME-$VERSION-$USHOT_ARCHITECTURE.zip"
EXPECTED_ENCLOSURE_URL="https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/$TAG/$EXPECTED_ARCHIVE_NAME"

[[ "$FIRST_ITEM_VERSION" == "$BUILD_NUMBER" ]] \
  || release_die "First appcast item build is $FIRST_ITEM_VERSION; expected $BUILD_NUMBER."
[[ "$FIRST_ITEM_SHORT_VERSION" == "$VERSION" ]] \
  || release_die "First appcast item version is $FIRST_ITEM_SHORT_VERSION; expected $VERSION."
[[ "$ENCLOSURE_URL" == "$EXPECTED_ENCLOSURE_URL" ]] \
  || release_die "Appcast enclosure URL mismatch: $ENCLOSURE_URL"
[[ "$ENCLOSURE_LENGTH" == "$(release_file_size "$ARCHIVE_PATH")" ]] \
  || release_die "Appcast enclosure length does not match the ZIP."
[[ -n "$ENCLOSURE_SIGNATURE" ]] \
  || release_die "Appcast enclosure has no EdDSA signature. The CI private key may not match SUPublicEDKey."
[[ "$EMBEDDED_NOTES" == "$EXPECTED_NOTES" ]] \
  || release_die "First appcast item does not embed the exact release-notes source."
grep -Eq 'sparkle-signatures:' "$APPCAST_PATH" \
  || release_die "Appcast has no signed-feed signature block."
grep -Eq '^[[:space:]]*edSignature:[[:space:]]*[A-Za-z0-9+/=]+' "$APPCAST_PATH" \
  || release_die "Appcast signed-feed block has no EdDSA signature."
grep -Eq 'sparkle-sign-warning:' "$APPCAST_PATH" \
  || release_die "Appcast is missing Sparkle's signed-file mutation warning."
if grep -Eq 'sparkle-sign-warning:|sparkle-signatures:' "$RELEASE_NOTES_PATH"; then
  release_die "Release-notes source must remain unsigned before it is embedded in the signed appcast."
fi

release_log "Validated signed appcast with embedded Markdown notes and signed $EXPECTED_ARCHIVE_NAME for $TAG."
