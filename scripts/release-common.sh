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
USHOT_APPCAST_URL="https://ischeneycc.github.io/ushot/updates/appcast.xml"
USHOT_SPARKLE_VERSION="2.9.5"
USHOT_SPARKLE_ARCHIVE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"
USHOT_SPARKLE_KEY_ACCOUNT="io.github.ischeneycc.ushot"
USHOT_SPARKLE_PUBLIC_ED_KEY="gdZAswkBeWYGYjpqCUmtrUEuyIc/RP5DO+c5I7h+h3Q="
USHOT_SPARKLE_XML_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"

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

release_validate_app_identity() {
  local app_path="$1"
  local expected_version="$2"
  local expected_build="$3"
  local info_plist="$app_path/Contents/Info.plist"
  local executable="$app_path/Contents/MacOS/$USHOT_EXECUTABLE_NAME"
  local sparkle_binary="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"

  [[ -d "$app_path" ]] || release_die "App bundle not found: $app_path"
  [[ "$(basename "$app_path")" == "$USHOT_APP_BUNDLE" ]] \
    || release_die "Release product must be named $USHOT_APP_BUNDLE: $app_path"
  [[ -f "$info_plist" ]] || release_die "App Info.plist not found: $info_plist"
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
  [[ "$sparkle_public_key" == "$USHOT_SPARKLE_PUBLIC_ED_KEY" ]] \
    || release_die "Built app does not contain Ushot's expected Sparkle Ed25519 public key."
  [[ -x "$executable" ]] \
    || release_die "Built app executable is missing or is not executable."
  [[ -x "$sparkle_binary" ]] \
    || release_die "Built app is missing Sparkle's embedded framework binary."
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
