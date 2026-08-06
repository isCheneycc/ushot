#!/bin/bash

# Shared, side-effect-free validation helpers for Ushot release tooling.
# Callers are responsible for enabling `set -euo pipefail` before sourcing.

USHOT_PRODUCT_NAME="Ushot"
USHOT_APP_BUNDLE="Ushot.app"
USHOT_BUNDLE_IDENTIFIER="io.github.ischeneycc.ushot"
USHOT_EXECUTABLE_NAME="Ushot"
USHOT_LEGACY_APP_BUNDLE="UshotApp.app"
USHOT_LEGACY_BUNDLE_IDENTIFIER="com.example.UshotApp"
USHOT_LEGACY_EXECUTABLE_NAME="UshotApp"
USHOT_ARCHITECTURE="arm64"
USHOT_GITHUB_REPOSITORY="isCheneycc/ushot"
USHOT_APPCAST_ORIGIN="https://ischeneycc.github.io/ushot"
USHOT_APPCAST_RELATIVE_PATH="updates/v1/appcast.xml"
USHOT_APPCAST_URL="$USHOT_APPCAST_ORIGIN/$USHOT_APPCAST_RELATIVE_PATH"
USHOT_LEGACY_APPCAST_RELATIVE_PATH="updates/appcast.xml"
USHOT_LEGACY_APPCAST_URL="$USHOT_APPCAST_ORIGIN/$USHOT_LEGACY_APPCAST_RELATIVE_PATH"
USHOT_APPCAST_CHANNEL_TITLE="Ushot Updates"
USHOT_APPCAST_CHANNEL_DESCRIPTION="Stable Ushot updates for macOS."
USHOT_APPCAST_CHANNEL_LANGUAGE="en"
USHOT_SPARKLE_VERSION="2.9.5"
USHOT_SPARKLE_ARCHIVE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"
USHOT_UPDATE_TRANSITION_SPARKLE_VERSION="2.9.5-ushot.2"
USHOT_UPDATE_TRANSITION_SPARKLE_BUILD="2062"
USHOT_SIGNED_FEED_VALIDATION_SPARKLE_VERSION="2.9.5-ushot.4"
USHOT_SIGNED_FEED_VALIDATION_SPARKLE_BUILD="2064"
USHOT_SPARKLE_KEY_ACCOUNT="io.github.ischeneycc.ushot.20260806"
USHOT_SPARKLE_PUBLIC_ED_KEY="+zRL11/2yYePt5O+OetThnLGwyvAvFtPPXxiBBOTTjE="
USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY="gdZAswkBeWYGYjpqCUmtrUEuyIc/RP5DO+c5I7h+h3Q="
USHOT_SPARKLE_XML_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"
USHOT_MAX_AUTHENTICATED_APPCAST_BYTES="1048576"
USHOT_SIGNED_APPCAST_TRAILER_ALLOWANCE_BYTES="512"
USHOT_MAX_SIGNED_APPCAST_BYTES="1049088"
USHOT_PUBLIC_UPDATE_BASELINE_VERSION="0.1.1"
USHOT_PUBLIC_UPDATE_BASELINE_BUILD="2"
USHOT_PUBLIC_UPDATE_BASELINE_SPARKLE_BUILD="2060"
USHOT_UPDATE_TRANSITION_VERSION="0.1.2"
USHOT_UPDATE_TRANSITION_BUILD="3"
USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION="0.1.3"
USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD="4"
USHOT_FIRST_FEED_VERSION="0.1.4"
USHOT_FIRST_FEED_BUILD="5"

release_log() {
  printf 'release: %s\n' "$*"
}

release_warn() {
  printf 'warning: %s\n' "$*" >&2
}

release_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

release_require_command() {
  command -v "$1" >/dev/null 2>&1 || release_die "Required command is unavailable: $1"
}

release_validate_openssl_salted_ciphertext() {
  local encrypted_path="$1"
  local header_hex

  [[ -f "$encrypted_path" && ! -L "$encrypted_path" ]] \
    || release_die "Encrypted backup must be a regular, non-symbolic-link file."
  [[ -x /usr/bin/od && -x /usr/bin/tr ]] \
    || release_die "Required system tools for encrypted-backup validation are unavailable."
  if ! header_hex="$(
    /usr/bin/od -An -tx1 -N8 "$encrypted_path" \
      | /usr/bin/tr -d '[:space:]'
  )"; then
    release_die "Could not inspect the encrypted backup header."
  fi
  [[ "$header_hex" == "53616c7465645f5f" ]] \
    || release_die "Encrypted backup is missing the OpenSSL Salted__ header."
}

release_validate_authenticated_appcast_runtime_policy() {
  local appcast_path="$1"
  local validator_path="${USHOT_AUTHENTICATED_APPCAST_VALIDATOR:-}"
  local validator_sha256="${USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256:-}"
  local canonical_validator_path

  [[ -s "$appcast_path" ]] \
    || release_die "Authenticated appcast is missing or empty: $appcast_path"
  [[ -n "$validator_path" && -n "$validator_sha256" ]] \
    || release_die "Authenticated appcast runtime validation requires a prebuilt validator path and SHA-256."
  case "$validator_path" in
    /*) ;;
    *) release_die "Authenticated appcast runtime validator path must be absolute." ;;
  esac
  [[ "$(basename "$validator_path")" == "AuthenticatedAppcastValidator" ]] \
    || release_die "Authenticated appcast runtime validator has an unexpected executable name."
  [[ "$validator_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Authenticated appcast runtime validator SHA-256 must be 64 lowercase hexadecimal characters."
  [[ -f "$validator_path" \
      && ! -L "$validator_path" \
      && -x "$validator_path" ]] \
    || release_die "Authenticated appcast runtime validator must be an executable regular non-symbolic file: $validator_path"
  canonical_validator_path="$({
    cd "$(dirname "$validator_path")" && \
      printf '%s/%s' "$(pwd -P)" "$(basename "$validator_path")"
  })"
  [[ "$canonical_validator_path" == "$validator_path" ]] \
    || release_die "Authenticated appcast runtime validator path must be canonical."
  [[ "$(release_sha256 "$validator_path")" == "$validator_sha256" ]] \
    || release_die "Authenticated appcast runtime validator checksum does not match the reviewed executable."
  /usr/bin/codesign --verify --strict "$validator_path" \
    || release_die "Authenticated appcast runtime validator failed code-signature validation."
  "$validator_path" "$appcast_path" \
    || release_die "Authenticated appcast failed the reviewed runtime XML policy."
}

release_validate_version() {
  local version="$1"
  if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    release_die "Version must be a stable semantic version in X.Y.Z form: $version"
  fi
}

release_validate_build_number() {
  local build_number="$1"
  if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    release_die "Build number must be a positive base-10 integer: $build_number"
  fi
}

release_decimal_is_strictly_greater() {
  local candidate="$1"
  local previous="$2"
  local LC_ALL=C

  [[ "$candidate" =~ ^(0|[1-9][0-9]*)$ ]] \
    || release_die "Decimal comparison candidate is not canonical: $candidate"
  [[ "$previous" =~ ^(0|[1-9][0-9]*)$ ]] \
    || release_die "Decimal comparison baseline is not canonical: $previous"

  if (( ${#candidate} > ${#previous} )); then
    return 0
  fi
  if (( ${#candidate} < ${#previous} )); then
    return 1
  fi
  [[ "$candidate" > "$previous" ]]
}

release_version_is_strictly_greater() {
  local candidate="$1"
  local previous="$2"
  local candidate_major candidate_minor candidate_patch
  local previous_major previous_minor previous_patch
  local candidate_component previous_component

  release_validate_version "$candidate"
  release_validate_version "$previous"
  IFS='.' read -r candidate_major candidate_minor candidate_patch <<< "$candidate"
  IFS='.' read -r previous_major previous_minor previous_patch <<< "$previous"

  for pair in \
    "$candidate_major:$previous_major" \
    "$candidate_minor:$previous_minor" \
    "$candidate_patch:$previous_patch"; do
    candidate_component="${pair%%:*}"
    previous_component="${pair#*:}"
    if release_decimal_is_strictly_greater "$candidate_component" "$previous_component"; then
      return 0
    fi
    if release_decimal_is_strictly_greater "$previous_component" "$candidate_component"; then
      return 1
    fi
  done
  return 1
}

release_validate_update_rollout_constants() {
  release_validate_version "$USHOT_PUBLIC_UPDATE_BASELINE_VERSION"
  release_validate_build_number "$USHOT_PUBLIC_UPDATE_BASELINE_BUILD"
  release_validate_version "$USHOT_UPDATE_TRANSITION_VERSION"
  release_validate_build_number "$USHOT_UPDATE_TRANSITION_BUILD"
  release_validate_version "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION"
  release_validate_build_number "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD"
  release_validate_version "$USHOT_FIRST_FEED_VERSION"
  release_validate_build_number "$USHOT_FIRST_FEED_BUILD"

  release_version_is_strictly_greater \
    "$USHOT_UPDATE_TRANSITION_VERSION" \
    "$USHOT_PUBLIC_UPDATE_BASELINE_VERSION" \
    || release_die "Update transition version must be newer than the public baseline."
  release_decimal_is_strictly_greater \
    "$USHOT_UPDATE_TRANSITION_BUILD" \
    "$USHOT_PUBLIC_UPDATE_BASELINE_BUILD" \
    || release_die "Update transition build must be newer than the public baseline."
  release_version_is_strictly_greater \
    "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" \
    "$USHOT_UPDATE_TRANSITION_VERSION" \
    || release_die "Signed-feed validation transition version must be newer than the update transition."
  release_decimal_is_strictly_greater \
    "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" \
    "$USHOT_UPDATE_TRANSITION_BUILD" \
    || release_die "Signed-feed validation transition build must be newer than the update transition."
  release_version_is_strictly_greater \
    "$USHOT_FIRST_FEED_VERSION" \
    "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" \
    || release_die "First-feed version must be newer than the signed-feed validation transition."
  release_decimal_is_strictly_greater \
    "$USHOT_FIRST_FEED_BUILD" \
    "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" \
    || release_die "First-feed build must be newer than the signed-feed validation transition."
}

release_is_first_feed_identity() {
  local version="$1"
  local build_number="$2"

  [[ "$version" == "$USHOT_FIRST_FEED_VERSION" \
      && "$build_number" == "$USHOT_FIRST_FEED_BUILD" ]]
}

release_validate_feed_release_identity() {
  local version="$1"
  local build_number="$2"

  release_validate_version "$version"
  release_validate_build_number "$build_number"
  release_validate_update_rollout_constants

  if release_is_first_feed_identity "$version" "$build_number"; then
    return 0
  fi

  release_version_is_strictly_greater "$version" "$USHOT_FIRST_FEED_VERSION" \
    || release_die "Feed publication version $version must be $USHOT_FIRST_FEED_VERSION or newer."
  release_decimal_is_strictly_greater "$build_number" "$USHOT_FIRST_FEED_BUILD" \
    || release_die "Feed publication build $build_number must be $USHOT_FIRST_FEED_BUILD or newer."
}

release_validate_appcast_channel_field() {
  local appcast_path="$1"
  local channel_xpath="$2"
  local element_name="$3"
  local expected_value="$4"
  local field_label="$5"
  local canonical_count
  local total_count
  local actual_value

  canonical_count="$(xmllint --xpath "count($channel_xpath/*[local-name()='$element_name' and namespace-uri()=''])" "$appcast_path")"
  total_count="$(xmllint --xpath "count($channel_xpath/*[local-name()='$element_name'])" "$appcast_path")"
  [[ "$canonical_count" == "1" && "$total_count" == "1" ]] \
    || release_die "Appcast channel must contain exactly one canonical $field_label."
  actual_value="$(xmllint --xpath "string($channel_xpath/*[local-name()='$element_name' and namespace-uri()=''])" "$appcast_path")"
  [[ "$actual_value" == "$expected_value" ]] \
    || release_die "Appcast channel has an unexpected $field_label: $actual_value"
}

release_validate_canonical_appcast_channel() {
  local appcast_path="$1"
  local channel_xpath="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']"

  release_validate_appcast_channel_field \
    "$appcast_path" "$channel_xpath" "title" "$USHOT_APPCAST_CHANNEL_TITLE" "title"
  release_validate_appcast_channel_field \
    "$appcast_path" "$channel_xpath" "link" "$USHOT_APPCAST_URL" "versioned feed link"
  release_validate_appcast_channel_field \
    "$appcast_path" "$channel_xpath" "description" "$USHOT_APPCAST_CHANNEL_DESCRIPTION" "description"
  release_validate_appcast_channel_field \
    "$appcast_path" "$channel_xpath" "language" "$USHOT_APPCAST_CHANNEL_LANGUAGE" "language"
}

release_validate_release_notes_content() {
  local notes="$1"

  [[ -n "${notes//[[:space:]]/}" ]] \
    || release_die "Release notes must contain non-whitespace text."
  case "$notes" in
    *'['*|*']'*|*'<'*|*'>'*|*'&'*|*'@'*|*'\'*)
      release_die "Release notes must not contain links, images, raw HTML, autolinks, or entities."
      ;;
  esac
  if printf '%s' "$notes" | LC_ALL=C grep -Eiq '(^|[^[:alnum:]])[[:alpha:]][[:alnum:]+.-]*:|://|//|www\.'; then
    release_die "Release notes must not contain URL-like destinations."
  fi
  if printf '%s' "$notes" | LC_ALL=C grep -Eiq '[[:alpha:]][[:alnum:]-]*\.[[:alpha:]][[:alpha:]-]*'; then
    release_die "Release notes must not contain bare domain-like destinations."
  fi
  if printf '%s' "$notes" | LC_ALL=C grep -Eiq '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)|::|localhost'; then
    release_die "Release notes must not contain network-address-like destinations."
  fi
}

release_validate_release_notes_source() {
  local notes_path="$1"
  local notes

  [[ -s "$notes_path" ]] || release_die "Release notes are missing or empty: $notes_path"
  notes="$(<"$notes_path")"
  release_validate_release_notes_content "$notes"
}

release_validate_tag() {
  local tag="$1"
  local version="$2"
  [[ "$tag" == "v$version" ]] || release_die "Tag $tag does not exactly match version $version (expected v$version)."
}

release_xcconfig_value() {
  local key="$1"
  local xcconfig_path="$2"
  local value
  value="$({ sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$xcconfig_path" || true; } | tail -n 1)"
  value="$(printf '%s' "$value" | sed 's/[[:space:]][[:space:]]*\/\/.*$//' | sed 's/[[:space:]]*$//')"
  printf '%s' "$value"
}

release_validate_source_settings() {
  local project_root="$1"
  local expected_version="${2:-}"
  local expected_build="${3:-}"
  local base_config="$project_root/Config/Base.xcconfig"
  local product_identity_source="$project_root/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift"

  [[ -f "$base_config" ]] || release_die "Missing source-of-truth configuration: $base_config"
  [[ "$(release_xcconfig_value PRODUCT_NAME "$base_config")" == "$USHOT_PRODUCT_NAME" ]] \
    || release_die "PRODUCT_NAME must be $USHOT_PRODUCT_NAME."
  [[ "$(release_xcconfig_value APP_BUNDLE_IDENTIFIER "$base_config")" == "$USHOT_BUNDLE_IDENTIFIER" ]] \
    || release_die "APP_BUNDLE_IDENTIFIER must be $USHOT_BUNDLE_IDENTIFIER."
  [[ "$(release_xcconfig_value SPARKLE_KEY_ACCOUNT "$base_config")" == "$USHOT_SPARKLE_KEY_ACCOUNT" ]] \
    || release_die "SPARKLE_KEY_ACCOUNT must be $USHOT_SPARKLE_KEY_ACCOUNT."
  [[ "$(release_xcconfig_value LD_RUNPATH_SEARCH_PATHS "$base_config")" == '$(inherited) @executable_path/../Frameworks' ]] \
    || release_die "LD_RUNPATH_SEARCH_PATHS must load embedded frameworks from @executable_path/../Frameworks."
  local sparkle_public_key
  sparkle_public_key="$(release_xcconfig_value SPARKLE_PUBLIC_ED_KEY "$base_config")"
  [[ "$sparkle_public_key" == "$USHOT_SPARKLE_PUBLIC_ED_KEY" ]] \
    || release_die "SPARKLE_PUBLIC_ED_KEY does not match Ushot's committed update key."
  [[ -f "$product_identity_source" && ! -L "$product_identity_source" ]] \
    || release_die "Missing or symbolic ProductIdentity source: $product_identity_source"
  [[ "$(grep -c '^[[:space:]]*public static let sparklePublicEDKey[[:space:]]*=[[:space:]]*$' "$product_identity_source")" == "1" ]] \
    || release_die "ProductIdentity must declare exactly one canonical sparklePublicEDKey constant."
  local product_identity_public_key_line
  product_identity_public_key_line="$({
    sed -n '/^[[:space:]]*public static let sparklePublicEDKey[[:space:]]*=[[:space:]]*$/{n;p;}' \
      "$product_identity_source"
  })"
  [[ "$product_identity_public_key_line" == "        \"$USHOT_SPARKLE_PUBLIC_ED_KEY\"" ]] \
    || release_die "ProductIdentity sparklePublicEDKey does not match Ushot's committed update key."

  if [[ -n "$expected_version" ]]; then
    [[ "$(release_xcconfig_value MARKETING_VERSION "$base_config")" == "$expected_version" ]] \
      || release_die "Config MARKETING_VERSION must equal release version $expected_version."
  fi
  if [[ -n "$expected_build" ]]; then
    [[ "$(release_xcconfig_value CURRENT_PROJECT_VERSION "$base_config")" == "$expected_build" ]] \
      || release_die "Config CURRENT_PROJECT_VERSION must equal release build $expected_build."
  fi
}

release_plist_value() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null \
    || release_die "Missing $key in $plist_path"
}

release_require_plist_type() {
  local plist_path="$1"
  local key="$2"
  local expected_type="$3"
  local actual_type

  actual_type="$(/usr/bin/plutil -type "$key" "$plist_path" 2>/dev/null)" \
    || release_die "Missing $key in $plist_path"
  [[ "$actual_type" == "$expected_type" ]] \
    || release_die "$key in $plist_path must have plist type $expected_type; got $actual_type."
}

release_validate_public_update_baseline_app_identity() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"
  local executable="$app_path/Contents/MacOS/$USHOT_EXECUTABLE_NAME"
  local sparkle_binary="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
  local sparkle_info_plist="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
  local string_key
  local boolean_key
  local absent_key

  [[ -d "$app_path" ]] || release_die "Public update baseline app bundle not found: $app_path"
  [[ "$(basename "$app_path")" == "$USHOT_APP_BUNDLE" ]] \
    || release_die "Public update baseline must be named $USHOT_APP_BUNDLE: $app_path"
  [[ -f "$info_plist" ]] || release_die "Public update baseline Info.plist not found: $info_plist"

  for string_key in \
    CFBundleIdentifier \
    CFBundleName \
    CFBundleExecutable \
    CFBundleShortVersionString \
    CFBundleVersion \
    SUFeedURL \
    SUPublicEDKey
  do
    release_require_plist_type "$info_plist" "$string_key" string
  done
  for boolean_key in \
    SURequireSignedFeed \
    SUVerifyUpdateBeforeExtraction \
    SUEnableAutomaticChecks \
    SUAutomaticallyUpdate \
    SUAllowsAutomaticUpdates \
    SUEnableSystemProfiling
  do
    release_require_plist_type "$info_plist" "$boolean_key" bool
  done
  release_require_plist_type \
    "$info_plist" \
    SUSignedFeedFailureExpirationInterval \
    integer

  [[ "$(release_plist_value "$info_plist" CFBundleIdentifier)" == "$USHOT_BUNDLE_IDENTIFIER" ]] \
    || release_die "Public update baseline has an unexpected bundle identifier."
  [[ "$(release_plist_value "$info_plist" CFBundleName)" == "$USHOT_PRODUCT_NAME" ]] \
    || release_die "Public update baseline has an unexpected product name."
  [[ "$(release_plist_value "$info_plist" CFBundleExecutable)" == "$USHOT_EXECUTABLE_NAME" ]] \
    || release_die "Public update baseline has an unexpected executable name."
  [[ "$(release_plist_value "$info_plist" CFBundleShortVersionString)" == "$USHOT_PUBLIC_UPDATE_BASELINE_VERSION" ]] \
    || release_die "Public update baseline version must be $USHOT_PUBLIC_UPDATE_BASELINE_VERSION."
  [[ "$(release_plist_value "$info_plist" CFBundleVersion)" == "$USHOT_PUBLIC_UPDATE_BASELINE_BUILD" ]] \
    || release_die "Public update baseline build must be $USHOT_PUBLIC_UPDATE_BASELINE_BUILD."
  [[ "$(release_plist_value "$info_plist" SUFeedURL)" == "$USHOT_LEGACY_APPCAST_URL" ]] \
    || release_die "Public update baseline must retain the isolated legacy Sparkle feed URL."
  [[ "$(release_plist_value "$info_plist" SUPublicEDKey)" == "$USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY" ]] \
    || release_die "Public update baseline does not contain Ushot's historical Sparkle Ed25519 public key."
  [[ "$(release_plist_value "$info_plist" SURequireSignedFeed)" == "true" ]] \
    || release_die "Public update baseline must require a signed Sparkle feed."
  [[ "$(release_plist_value "$info_plist" SUSignedFeedFailureExpirationInterval)" == "0" ]] \
    || release_die "Public update baseline must permanently fail closed when signed-feed verification fails."
  [[ "$(release_plist_value "$info_plist" SUVerifyUpdateBeforeExtraction)" == "true" ]] \
    || release_die "Public update baseline must verify updates before extraction."
  [[ "$(release_plist_value "$info_plist" SUEnableAutomaticChecks)" == "false" ]] \
    || release_die "Public update baseline must keep automatic update checks disabled."
  [[ "$(release_plist_value "$info_plist" SUAutomaticallyUpdate)" == "false" ]] \
    || release_die "Public update baseline must not install updates automatically."
  [[ "$(release_plist_value "$info_plist" SUAllowsAutomaticUpdates)" == "false" ]] \
    || release_die "Public update baseline must disallow automatic updates."
  [[ "$(release_plist_value "$info_plist" SUEnableSystemProfiling)" == "false" ]] \
    || release_die "Public update baseline must keep Sparkle system profiling disabled."

  for absent_key in \
    SURequireExactUpdateVersionIdentity \
    SURequireEdDSAUpdateArchiveSignature \
    SURequireHostSignedAppcastValidation \
    SUMaximumSignedAppcastContentLength
  do
    if /usr/bin/plutil -type "$absent_key" "$info_plist" >/dev/null 2>&1; then
      release_die "Public update baseline unexpectedly contains post-baseline key $absent_key."
    fi
  done

  [[ -x "$executable" ]] \
    || release_die "Public update baseline executable is missing or is not executable."
  [[ -x "$sparkle_binary" ]] \
    || release_die "Public update baseline is missing Sparkle's embedded framework binary."
  [[ -f "$sparkle_info_plist" ]] \
    || release_die "Public update baseline is missing Sparkle's embedded framework Info.plist."
  release_require_plist_type "$sparkle_info_plist" CFBundleShortVersionString string
  release_require_plist_type "$sparkle_info_plist" CFBundleVersion string
  [[ "$(release_plist_value "$sparkle_info_plist" CFBundleShortVersionString)" == "$USHOT_SPARKLE_VERSION" ]] \
    || release_die "Public update baseline has an unexpected Sparkle version."
  [[ "$(release_plist_value "$sparkle_info_plist" CFBundleVersion)" == "$USHOT_PUBLIC_UPDATE_BASELINE_SPARKLE_BUILD" ]] \
    || release_die "Public update baseline has an unexpected Sparkle build."
  if /usr/bin/plutil -type SUUpdateVersionIdentityHardeningVersion "$sparkle_info_plist" >/dev/null 2>&1; then
    release_die "Public update baseline unexpectedly contains the post-baseline Sparkle hardening marker."
  fi
  for absent_key in \
    SUHostSignedAppcastValidationVersion \
    SUFeedDownloadSizeLimitVersion
  do
    if /usr/bin/plutil -type "$absent_key" "$sparkle_info_plist" >/dev/null 2>&1; then
      release_die "Public update baseline unexpectedly contains post-baseline Sparkle marker $absent_key."
    fi
  done

  release_require_command otool
  otool -L "$executable" | awk '
    $1 == "@rpath/Sparkle.framework/Versions/B/Sparkle" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' || release_die "Public update baseline is not linked to its embedded Sparkle framework."
  otool -l "$executable" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
      if ($2 == "@executable_path/../Frameworks") { found = 1 }
      in_rpath = 0
    }
    END { exit(found ? 0 : 1) }
  ' || release_die "Public update baseline cannot resolve its embedded Sparkle framework."
  [[ -s "$app_path/Contents/Resources/ThirdPartyNotices.txt" ]] \
    || release_die "Public update baseline must include its third-party license notices."
  [[ -s "$app_path/Contents/Resources/LICENSE" ]] \
    || release_die "Public update baseline must include the Apache-2.0 license."
}

release_validate_supported_installed_app_identity() {
  local app_path="$1"
  local version="$2"
  local build_number="$3"

  if [[ "$version" == "$USHOT_PUBLIC_UPDATE_BASELINE_VERSION" \
      && "$build_number" == "$USHOT_PUBLIC_UPDATE_BASELINE_BUILD" ]]; then
    release_validate_public_update_baseline_app_identity "$app_path"
    return
  fi
  release_validate_app_identity "$app_path" "$version" "$build_number"
}

release_validate_app_identity() {
  local app_path="$1"
  local expected_version="$2"
  local expected_build="$3"
  local info_plist="$app_path/Contents/Info.plist"
  local executable="$app_path/Contents/MacOS/$USHOT_EXECUTABLE_NAME"
  local sparkle_binary="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
  local sparkle_info_plist="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
  local requires_host_signed_appcast_validation=true
  local expected_sparkle_version="$USHOT_SIGNED_FEED_VALIDATION_SPARKLE_VERSION"
  local expected_sparkle_build="$USHOT_SIGNED_FEED_VALIDATION_SPARKLE_BUILD"
  local expected_sparkle_public_key="$USHOT_SPARKLE_PUBLIC_ED_KEY"

  if [[ "$expected_version" == "$USHOT_UPDATE_TRANSITION_VERSION" \
      && "$expected_build" == "$USHOT_UPDATE_TRANSITION_BUILD" ]]; then
    requires_host_signed_appcast_validation=false
    expected_sparkle_version="$USHOT_UPDATE_TRANSITION_SPARKLE_VERSION"
    expected_sparkle_build="$USHOT_UPDATE_TRANSITION_SPARKLE_BUILD"
    expected_sparkle_public_key="$USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY"
  fi

  [[ -d "$app_path" ]] || release_die "App bundle not found: $app_path"
  [[ "$(basename "$app_path")" == "$USHOT_APP_BUNDLE" ]] \
    || release_die "Release product must be named $USHOT_APP_BUNDLE: $app_path"
  [[ -f "$info_plist" ]] || release_die "App Info.plist not found: $info_plist"
  local string_key
  for string_key in \
    CFBundleIdentifier \
    CFBundleName \
    CFBundleExecutable \
    CFBundleShortVersionString \
    CFBundleVersion \
    SUFeedURL \
    SUPublicEDKey
  do
    release_require_plist_type "$info_plist" "$string_key" string
  done
  local boolean_key
  for boolean_key in \
    SURequireSignedFeed \
    SURequireExactUpdateVersionIdentity \
    SURequireEdDSAUpdateArchiveSignature \
    SUVerifyUpdateBeforeExtraction \
    SUEnableAutomaticChecks \
    SUAutomaticallyUpdate \
    SUAllowsAutomaticUpdates \
    SUEnableSystemProfiling
  do
    release_require_plist_type "$info_plist" "$boolean_key" bool
  done
  if [[ "$requires_host_signed_appcast_validation" == "true" ]]; then
    release_require_plist_type \
      "$info_plist" \
      SURequireHostSignedAppcastValidation \
      bool
    release_require_plist_type \
      "$info_plist" \
      SUMaximumSignedAppcastContentLength \
      integer
  elif /usr/bin/plutil -type SURequireHostSignedAppcastValidation "$info_plist" >/dev/null 2>&1; then
    release_die "Historical update transition unexpectedly requires the later host signed-appcast validator."
  elif /usr/bin/plutil -type SUMaximumSignedAppcastContentLength "$info_plist" >/dev/null 2>&1; then
    release_die "Historical update transition unexpectedly contains the later signed-appcast size limit."
  fi
  release_require_plist_type \
    "$info_plist" \
    SUSignedFeedFailureExpirationInterval \
    integer
  [[ "$(release_plist_value "$info_plist" CFBundleIdentifier)" == "$USHOT_BUNDLE_IDENTIFIER" ]] \
    || release_die "Built app has an unexpected bundle identifier."
  [[ "$(release_plist_value "$info_plist" CFBundleName)" == "$USHOT_PRODUCT_NAME" ]] \
    || release_die "Built app has an unexpected product name."
  [[ "$(release_plist_value "$info_plist" CFBundleExecutable)" == "$USHOT_EXECUTABLE_NAME" ]] \
    || release_die "Built app has an unexpected executable name."
  [[ "$(release_plist_value "$info_plist" CFBundleShortVersionString)" == "$expected_version" ]] \
    || release_die "Built app version does not equal $expected_version."
  [[ "$(release_plist_value "$info_plist" CFBundleVersion)" == "$expected_build" ]] \
    || release_die "Built app build number does not equal $expected_build."
  [[ "$(release_plist_value "$info_plist" SUFeedURL)" == "$USHOT_APPCAST_URL" ]] \
    || release_die "Built app has an unexpected Sparkle feed URL."
  [[ "$(release_plist_value "$info_plist" SURequireSignedFeed)" == "true" ]] \
    || release_die "Built app must require a signed Sparkle feed."
  [[ "$(release_plist_value "$info_plist" SURequireExactUpdateVersionIdentity)" == "true" ]] \
    || release_die "Built app must require exact appcast/archive version identity."
  [[ "$(release_plist_value "$info_plist" SURequireEdDSAUpdateArchiveSignature)" == "true" ]] \
    || release_die "Built app must require an independent EdDSA archive signature."
  if [[ "$requires_host_signed_appcast_validation" == "true" ]]; then
    [[ "$(release_plist_value "$info_plist" SURequireHostSignedAppcastValidation)" == "true" ]] \
      || release_die "Built app must require host validation of authenticated appcast XML."
    [[ "$(release_plist_value "$info_plist" SUMaximumSignedAppcastContentLength)" == "$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES" ]] \
      || release_die "Built app must cap authenticated appcast XML at $USHOT_MAX_AUTHENTICATED_APPCAST_BYTES bytes."
  fi
  [[ "$(release_plist_value "$info_plist" SUSignedFeedFailureExpirationInterval)" == "0" ]] \
    || release_die "Built app must permanently fail closed when signed-feed verification fails."
  [[ "$(release_plist_value "$info_plist" SUVerifyUpdateBeforeExtraction)" == "true" ]] \
    || release_die "Built app must verify the update before extraction."
  [[ "$(release_plist_value "$info_plist" SUEnableAutomaticChecks)" == "false" ]] \
    || release_die "Built app must keep automatic update checks disabled."
  [[ "$(release_plist_value "$info_plist" SUAutomaticallyUpdate)" == "false" ]] \
    || release_die "Built app must not install updates automatically."
  [[ "$(release_plist_value "$info_plist" SUAllowsAutomaticUpdates)" == "false" ]] \
    || release_die "Built app must disallow automatic updates."
  [[ "$(release_plist_value "$info_plist" SUEnableSystemProfiling)" == "false" ]] \
    || release_die "Built app must keep Sparkle system profiling disabled."
  local sparkle_public_key
  sparkle_public_key="$(release_plist_value "$info_plist" SUPublicEDKey)"
  [[ "$sparkle_public_key" == "$expected_sparkle_public_key" ]] \
    || release_die "Built app does not contain Ushot's expected Sparkle Ed25519 public key."
  [[ -x "$executable" ]] \
    || release_die "Built app executable is missing or is not executable."
  [[ -x "$sparkle_binary" ]] \
    || release_die "Built app is missing Sparkle's embedded framework binary."
  [[ -f "$sparkle_info_plist" ]] \
    || release_die "Built app is missing Sparkle's embedded framework Info.plist."
  release_require_plist_type \
    "$sparkle_info_plist" \
    CFBundleShortVersionString \
    string
  release_require_plist_type \
    "$sparkle_info_plist" \
    CFBundleVersion \
    string
  [[ "$(release_plist_value "$sparkle_info_plist" CFBundleShortVersionString)" == "$expected_sparkle_version" ]] \
    || release_die "Embedded Sparkle framework version must equal $expected_sparkle_version."
  [[ "$(release_plist_value "$sparkle_info_plist" CFBundleVersion)" == "$expected_sparkle_build" ]] \
    || release_die "Embedded Sparkle framework build must equal $expected_sparkle_build."
  release_require_plist_type \
    "$sparkle_info_plist" \
    SUUpdateVersionIdentityHardeningVersion \
    integer
  [[ "$(release_plist_value "$sparkle_info_plist" SUUpdateVersionIdentityHardeningVersion)" == "1" ]] \
    || release_die "Embedded Sparkle framework is missing Ushot update hardening marker version 1."
  if [[ "$requires_host_signed_appcast_validation" == "true" ]]; then
    release_require_plist_type \
      "$sparkle_info_plist" \
      SUHostSignedAppcastValidationVersion \
      integer
    [[ "$(release_plist_value "$sparkle_info_plist" SUHostSignedAppcastValidationVersion)" == "1" ]] \
      || release_die "Embedded Sparkle framework is missing host signed-appcast validation marker version 1."
    release_require_plist_type \
      "$sparkle_info_plist" \
      SUFeedDownloadSizeLimitVersion \
      integer
    [[ "$(release_plist_value "$sparkle_info_plist" SUFeedDownloadSizeLimitVersion)" == "1" ]] \
      || release_die "Embedded Sparkle framework is missing feed download-size limit marker version 1."
  else
    local post_transition_marker
    for post_transition_marker in \
      SUHostSignedAppcastValidationVersion \
      SUFeedDownloadSizeLimitVersion
    do
      if /usr/bin/plutil -type "$post_transition_marker" "$sparkle_info_plist" >/dev/null 2>&1; then
        release_die "Historical update transition unexpectedly contains later Sparkle marker $post_transition_marker."
      fi
    done
  fi
  release_require_command otool
  otool -L "$executable" | awk '
    $1 == "@rpath/Sparkle.framework/Versions/B/Sparkle" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' || release_die "Built app executable is not linked to the pinned embedded Sparkle framework."
  otool -l "$executable" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
      if ($2 == "@executable_path/../Frameworks") { found = 1 }
      in_rpath = 0
    }
    END { exit(found ? 0 : 1) }
  ' || release_die "Built app cannot resolve embedded frameworks: missing @executable_path/../Frameworks LC_RPATH."
  [[ -s "$app_path/Contents/Resources/ThirdPartyNotices.txt" ]] \
    || release_die "Built app must include its third-party license notices."
  [[ -s "$app_path/Contents/Resources/LICENSE" ]] \
    || release_die "Built app must include the Apache-2.0 license."
}

release_signature_details() {
  local code_path="$1"
  codesign --display --verbose=4 "$code_path" 2>&1
}

release_verify_no_get_task_allow() {
  local app_path="$1"
  local candidate
  local entitlements
  local compact_entitlements

  while IFS= read -r -d '' candidate; do
    if ! file -b "$candidate" | grep -q 'Mach-O'; then
      continue
    fi
    codesign --verify --strict "$candidate" \
      || release_die "Unsigned or invalid Mach-O code found inside the app: $candidate"
    entitlements="$(codesign --display --entitlements :- "$candidate" 2>/dev/null)" \
      || release_die "Could not inspect entitlements for $candidate"
    compact_entitlements="$(printf '%s' "$entitlements" | tr -d '[:space:]')"
    if [[ "$compact_entitlements" == *'<key>com.apple.security.get-task-allow</key><true/>'* ]]; then
      release_die "Development entitlement com.apple.security.get-task-allow is enabled in $candidate"
    fi
  done < <(find "$app_path/Contents" -type f -perm -111 -print0)
}

release_verify_signature_mode() {
  local app_path="$1"
  local mode="$2"
  local details
  local team_identifier
  local signing_requirement

  codesign --verify --deep --strict --verbose=2 "$app_path"
  details="$(release_signature_details "$app_path")"
  team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"

  case "$mode" in
    public-adhoc)
      grep -q '^Signature=adhoc$' <<<"$details" \
        || release_die "Public artifact must have an explicit ad-hoc signature."
      [[ -z "$team_identifier" || "$team_identifier" == "not set" ]] \
        || release_die "Public ad-hoc artifact unexpectedly has TeamIdentifier=$team_identifier"
      if grep -q '^Authority=Apple Development' <<<"$details"; then
        release_die "Public artifact was signed with an Apple Development certificate."
      fi
      if grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$details"; then
        release_die "Public ad-hoc host unexpectedly has Hardened Runtime enabled."
      fi
      ;;
    local-signed)
      ! grep -q '^Signature=adhoc$' <<<"$details" \
        || release_die "Local signed artifact is ad-hoc signed."
      [[ "$team_identifier" =~ ^[A-Z0-9]{10}$ ]] \
        || release_die "Local signed artifact has an invalid TeamIdentifier: $team_identifier"
      signing_requirement="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.12] /* exists */ and certificate leaf[subject.OU] = \"$team_identifier\""
      codesign --verify --strict "-R=$signing_requirement" "$app_path" \
        || release_die "Local signed mode requires an Apple Development certificate for TeamIdentifier=$team_identifier."
      grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$details" \
        || release_die "Local signed mode must keep Hardened Runtime enabled."
      ;;
    developer-id)
      ! grep -q '^Signature=adhoc$' <<<"$details" \
        || release_die "Developer ID artifact is ad-hoc signed."
      [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] \
        || release_die "Developer ID artifact has no TeamIdentifier."
      grep -q '^Authority=Developer ID Application' <<<"$details" \
        || release_die "Developer ID mode requires a Developer ID Application certificate."
      grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$details" \
        || release_die "Developer ID mode must keep Hardened Runtime enabled."
      ;;
    *)
      release_die "Unsupported signature mode: $mode"
      ;;
  esac

  release_verify_no_get_task_allow "$app_path"
}

release_verify_dsym() {
  local app_path="$1"
  local dsym_path="$2"
  local executable="$app_path/Contents/MacOS/$USHOT_EXECUTABLE_NAME"
  local app_uuids
  local dsym_uuids

  [[ -d "$dsym_path" ]] || release_die "Required dSYM bundle not found: $dsym_path"
  app_uuids="$(dwarfdump --uuid "$executable" | awk '{print $2}' | sort)"
  dsym_uuids="$(dwarfdump --uuid "$dsym_path" | awk '{print $2}' | sort)"
  [[ -n "$app_uuids" ]] || release_die "Could not read UUIDs from $executable"
  [[ "$app_uuids" == "$dsym_uuids" ]] \
    || release_die "dSYM UUIDs do not match the Ushot executable."
}

release_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

release_file_size() {
  stat -f '%z' "$1"
}
