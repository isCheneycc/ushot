#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FETCH_SCRIPT="$SCRIPT_DIR/fetch-current-appcast.sh"
GENERATE_SCRIPT="$SCRIPT_DIR/generate-appcast.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-appcast.sh"
DERIVE_KEY_SCRIPT="$SCRIPT_DIR/derive-sparkle-public-key.swift"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"
# shellcheck source=install-local.sh
source "$SCRIPT_DIR/install-local.sh"

mkdir -p "$PROJECT_ROOT/build"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ushot-feed-gates.XXXXXX")"
SITE_DIRECTORY="$(mktemp -d "$PROJECT_ROOT/build/test-release-feed-gates.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT" "$SITE_DIRECTORY"
}
trap cleanup EXIT

PASS_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %d - %s\n' "$PASS_COUNT" "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

expect_success() {
  local name="$1"
  shift
  local output

  if ! output="$({ "$@"; } 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$name"
  fi
  pass "$name"
}

expect_output() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  if ! output="$({ "$@"; } 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$name"
  fi
  [[ "$output" == "$expected" ]] || {
    printf 'expected: %s\nactual: %s\n' "$expected" "$output" >&2
    fail "$name"
  }
  pass "$name"
}

expect_failure_containing() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  local status

  set +e
  output="$({ "$@"; } 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$name unexpectedly succeeded"
  case "$output" in
    *"$expected"*) ;;
    *)
      printf '%s\n' "$output" >&2
      fail "$name did not report: $expected"
      ;;
  esac
  pass "$name"
}

assert_rollout_constants() {
  [[ "$USHOT_PUBLIC_UPDATE_BASELINE_VERSION" == "0.1.1" ]]
  [[ "$USHOT_PUBLIC_UPDATE_BASELINE_BUILD" == "2" ]]
  [[ "$USHOT_UPDATE_TRANSITION_VERSION" == "0.1.2" ]]
  [[ "$USHOT_UPDATE_TRANSITION_BUILD" == "3" ]]
  [[ "$USHOT_FIRST_FEED_VERSION" == "0.1.3" ]]
  [[ "$USHOT_FIRST_FEED_BUILD" == "4" ]]
  [[ "$USHOT_LEGACY_APPCAST_URL" == "https://ischeneycc.github.io/ushot/updates/appcast.xml" ]]
  [[ "$USHOT_LEGACY_APPCAST_RELATIVE_PATH" == "updates/appcast.xml" ]]
  [[ "$USHOT_APPCAST_RELATIVE_PATH" == "updates/v1/appcast.xml" ]]
  [[ "$USHOT_APPCAST_URL" == "https://ischeneycc.github.io/ushot/updates/v1/appcast.xml" ]]
  [[ -s "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" ]]
  [[ ! -e "$PROJECT_ROOT/$USHOT_LEGACY_APPCAST_RELATIVE_PATH" ]]
  release_validate_update_rollout_constants
  release_validate_feed_release_identity "0.1.3" "4"
  release_validate_feed_release_identity "0.1.4" "5"
}

reject_transition_feed() {
  release_validate_feed_release_identity "0.1.2" "3"
}

expect_success "rollout identities and versioned feed path are canonical" assert_rollout_constants
expect_failure_containing \
  "transition release cannot publish a feed" \
  "must be 0.1.3 or newer" \
  reject_transition_feed

RFC8032_SEED_BASE64="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
RFC8032_PUBLIC_BASE64="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

derive_rfc8032_key() {
  printf '%s' "$RFC8032_SEED_BASE64" | "$DERIVE_KEY_SCRIPT"
}

derive_noncanonical_key() {
  printf '%s\n' "$RFC8032_SEED_BASE64" | "$DERIVE_KEY_SCRIPT"
}

derive_invalid_base64_key() {
  printf '%s' 'not-base64' | "$DERIVE_KEY_SCRIPT"
}

derive_short_key() {
  printf '%s' 'YWJj' | "$DERIVE_KEY_SCRIPT"
}

expect_output \
  "CryptoKit derives the RFC 8032 Ed25519 public key" \
  "$RFC8032_PUBLIC_BASE64" \
  derive_rfc8032_key
expect_failure_containing \
  "key derivation rejects noncanonical base64 whitespace" \
  "canonical base64 without whitespace" \
  derive_noncanonical_key
expect_failure_containing \
  "key derivation rejects malformed base64" \
  "canonical base64 without whitespace" \
  derive_invalid_base64_key
expect_failure_containing \
  "key derivation rejects a seed that is not 32 bytes" \
  "exactly 32 bytes" \
  derive_short_key

PREFLIGHT_ROOT="$TEST_ROOT/preflight-repository"
mkdir -p \
  "$PREFLIGHT_ROOT/Config" \
  "$PREFLIGHT_ROOT/scripts" \
  "$PREFLIGHT_ROOT/updates/release-notes" \
  "$PREFLIGHT_ROOT/updates/v1"
cp "$SCRIPT_DIR/release-common.sh" "$PREFLIGHT_ROOT/scripts/release-common.sh"
cp "$SCRIPT_DIR/release-preflight.sh" "$PREFLIGHT_ROOT/scripts/release-preflight.sh"
cp "$DERIVE_KEY_SCRIPT" "$PREFLIGHT_ROOT/scripts/derive-sparkle-public-key.swift"
cp "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" "$PREFLIGHT_ROOT/$USHOT_APPCAST_RELATIVE_PATH"
chmod +x \
  "$PREFLIGHT_ROOT/scripts/release-common.sh" \
  "$PREFLIGHT_ROOT/scripts/release-preflight.sh" \
  "$PREFLIGHT_ROOT/scripts/derive-sparkle-public-key.swift"

write_preflight_config() {
  local version="$1"
  local build_number="$2"
  cat > "$PREFLIGHT_ROOT/Config/Base.xcconfig" <<EOF
PRODUCT_NAME = Ushot
APP_BUNDLE_IDENTIFIER = io.github.ischeneycc.ushot
SPARKLE_KEY_ACCOUNT = io.github.ischeneycc.ushot
SPARKLE_PUBLIC_ED_KEY = $USHOT_SPARKLE_PUBLIC_ED_KEY
LD_RUNPATH_SEARCH_PATHS = \$(inherited) @executable_path/../Frameworks
MARKETING_VERSION = $version
CURRENT_PROJECT_VERSION = $build_number
EOF
}

write_preflight_config "0.1.3" "4"
printf 'Release notes' > "$PREFLIGHT_ROOT/updates/release-notes/0.1.3.md"
git -C "$PREFLIGHT_ROOT" init -q
git -C "$PREFLIGHT_ROOT" config user.name "Ushot Test"
git -C "$PREFLIGHT_ROOT" config user.email "ushot-test@example.invalid"
git -C "$PREFLIGHT_ROOT" add .
git -C "$PREFLIGHT_ROOT" commit -qm "test: versioned feed preflight"
git -C "$PREFLIGHT_ROOT" tag "v0.1.3"

run_versioned_preflight() {
  "$PREFLIGHT_ROOT/scripts/release-preflight.sh" \
    --tag "v0.1.3" \
    --build-number "4" \
    --repository "$USHOT_GITHUB_REPOSITORY"
}

expect_success "release preflight validates the versioned seed path" run_versioned_preflight

write_preflight_config "0.1.4" "5"
printf 'Future notes' > "$PREFLIGHT_ROOT/updates/release-notes/0.1.4.md"
cp "$PREFLIGHT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" "$PREFLIGHT_ROOT/$USHOT_LEGACY_APPCAST_RELATIVE_PATH"
git -C "$PREFLIGHT_ROOT" add .
git -C "$PREFLIGHT_ROOT" commit -qm "test: forbidden legacy feed"
git -C "$PREFLIGHT_ROOT" tag "v0.1.4"

run_legacy_preflight() {
  "$PREFLIGHT_ROOT/scripts/release-preflight.sh" \
    --tag "v0.1.4" \
    --build-number "5" \
    --repository "$USHOT_GITHUB_REPOSITORY"
}

expect_failure_containing \
  "release preflight rejects a restored legacy feed path" \
  "Legacy appcast path must remain permanently absent" \
  run_legacy_preflight

rm "$PREFLIGHT_ROOT/$USHOT_LEGACY_APPCAST_RELATIVE_PATH"
ln -s missing-appcast.xml "$PREFLIGHT_ROOT/$USHOT_LEGACY_APPCAST_RELATIVE_PATH"
git -C "$PREFLIGHT_ROOT" add -A
git -C "$PREFLIGHT_ROOT" commit -qm "test: dangling legacy feed path"
git -C "$PREFLIGHT_ROOT" tag -f "v0.1.4" >/dev/null

expect_failure_containing \
  "release preflight rejects a dangling legacy feed symlink" \
  "Legacy appcast path must remain permanently absent" \
  run_legacy_preflight

APP_MOCK_BIN="$TEST_ROOT/app-mock-bin"
TEST_APP="$TEST_ROOT/Ushot.app"
mkdir -p \
  "$APP_MOCK_BIN" \
  "$TEST_APP/Contents/MacOS" \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources" \
  "$TEST_APP/Contents/Resources"
cat > "$APP_MOCK_BIN/otool" <<'MOCK_OTOOL'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  -L)
    printf '%s\n' '@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 2.0.0, current version 2.9.5)'
    ;;
  -l)
    printf '%s\n' 'cmd LC_RPATH' 'path @executable_path/../Frameworks (offset 12)'
    ;;
  *)
    exit 1
    ;;
esac
MOCK_OTOOL
chmod +x "$APP_MOCK_BIN/otool"
printf '#!/bin/bash\nexit 0\n' > "$TEST_APP/Contents/MacOS/Ushot"
printf '#!/bin/bash\nexit 0\n' > "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
chmod +x \
  "$TEST_APP/Contents/MacOS/Ushot" \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
printf 'notices' > "$TEST_APP/Contents/Resources/ThirdPartyNotices.txt"
printf 'license' > "$TEST_APP/Contents/Resources/LICENSE"
cat > "$TEST_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$USHOT_BUNDLE_IDENTIFIER</string>
  <key>CFBundleName</key><string>$USHOT_PRODUCT_NAME</string>
  <key>CFBundleExecutable</key><string>$USHOT_EXECUTABLE_NAME</string>
  <key>CFBundleShortVersionString</key><string>0.1.3</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>SUFeedURL</key><string>$USHOT_APPCAST_URL</string>
  <key>SUPublicEDKey</key><string>$USHOT_SPARKLE_PUBLIC_ED_KEY</string>
  <key>SURequireSignedFeed</key><true/>
  <key>SURequireExactUpdateVersionIdentity</key><true/>
  <key>SURequireEdDSAUpdateArchiveSignature</key><true/>
  <key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SUEnableSystemProfiling</key><false/>
</dict></plist>
EOF
cat > "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>2.9.5</string>
  <key>CFBundleVersion</key><string>2060</string>
  <key>SUUpdateVersionIdentityHardeningVersion</key><integer>1</integer>
</dict></plist>
EOF

validate_hardened_app() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity "$TEST_APP" "0.1.3" "4"
}

expect_success "built-app gate accepts both host requirements and framework marker 1" validate_hardened_app
/usr/libexec/PlistBuddy -c 'Set :SURequireExactUpdateVersionIdentity false' "$TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "built-app gate rejects a disabled exact-version requirement" \
  "must require exact appcast/archive version identity" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c 'Set :SURequireExactUpdateVersionIdentity true' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SURequireExactUpdateVersionIdentity' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SURequireExactUpdateVersionIdentity string true' "$TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "built-app gate rejects a string-typed exact-version requirement" \
  "must have plist type bool" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c 'Delete :SURequireExactUpdateVersionIdentity' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SURequireExactUpdateVersionIdentity bool true' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUUpdateVersionIdentityHardeningVersion 0' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
expect_failure_containing \
  "built-app gate rejects a framework without hardening marker 1" \
  "missing Ushot update hardening marker version 1" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c 'Delete :SUUpdateVersionIdentityHardeningVersion' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SUUpdateVersionIdentityHardeningVersion string 1' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
expect_failure_containing \
  "built-app gate rejects a string-typed hardening marker" \
  "must have plist type integer" \
  validate_hardened_app

BASELINE_TEST_ROOT="$TEST_ROOT/public-update-baseline"
BASELINE_TEST_APP="$BASELINE_TEST_ROOT/Ushot.app"
mkdir -p "$BASELINE_TEST_ROOT"
cp -R "$TEST_APP" "$BASELINE_TEST_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $USHOT_PUBLIC_UPDATE_BASELINE_VERSION" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $USHOT_PUBLIC_UPDATE_BASELINE_BUILD" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $USHOT_LEGACY_APPCAST_URL" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SURequireExactUpdateVersionIdentity' \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SURequireEdDSAUpdateArchiveSignature' \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SUUpdateVersionIdentityHardeningVersion' \
  "$BASELINE_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"

validate_public_update_baseline() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_supported_installed_app_identity \
    "$BASELINE_TEST_APP" \
    "$USHOT_PUBLIC_UPDATE_BASELINE_VERSION" \
    "$USHOT_PUBLIC_UPDATE_BASELINE_BUILD"
}

expect_success \
  "local installer accepts only the exact public update baseline for migration" \
  validate_public_update_baseline
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $USHOT_APPCAST_URL" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "local installer rejects a baseline bundle that crosses feed generations" \
  "must retain the isolated legacy Sparkle feed URL" \
  validate_public_update_baseline
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $USHOT_LEGACY_APPCAST_URL" \
  "$BASELINE_TEST_APP/Contents/Info.plist"

validate_current_baseline_callsite() (
  release_verify_signature_mode() { :; }
  release_team_identifier() { printf '%s' 'TESTTEAM01'; }
  release_designated_requirement() { printf '%s' 'test requirement'; }
  codesign() { :; }
  SOURCE_APP="$BASELINE_TEST_APP"
  PATH="$APP_MOCK_BIN:$PATH" validate_current_local_app \
    "$BASELINE_TEST_APP" \
    "TESTTEAM01" \
    "test replacement requirement"
)

validate_recovery_baseline_callsite() (
  release_verify_signature_mode() { :; }
  release_team_identifier() { printf '%s' 'TESTTEAM01'; }
  release_designated_requirement() { printf '%s' 'test requirement'; }
  PATH="$APP_MOCK_BIN:$PATH" validate_current_recovery_app \
    "$BASELINE_TEST_APP" \
    "TESTTEAM01" \
    "test requirement"
)

expect_success \
  "local install preflight callsite accepts the exact public update baseline" \
  validate_current_baseline_callsite
expect_success \
  "local install recovery callsite accepts the exact public update baseline" \
  validate_recovery_baseline_callsite
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.0' \
  "$BASELINE_TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "local install preflight callsite rejects a tampered baseline identity" \
  "Missing SURequireExactUpdateVersionIdentity" \
  validate_current_baseline_callsite
expect_failure_containing \
  "local install recovery callsite rejects a tampered baseline identity" \
  "Missing SURequireExactUpdateVersionIdentity" \
  validate_recovery_baseline_callsite

MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/curl" <<'MOCK_CURL'
#!/bin/bash
set -euo pipefail

output_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output_path="${2:?missing curl output path}"
      shift 2
      ;;
    --proto|--user-agent|--write-out)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$output_path" ]]
printf 'called' > "${MOCK_CURL_CALLED:?}"
if [[ -n "${MOCK_CURL_BODY:-}" ]]; then
  cp "$MOCK_CURL_BODY" "$output_path"
else
  : > "$output_path"
fi
printf '%s' "${MOCK_CURL_STATUS:?}"
MOCK_CURL
chmod +x "$MOCK_BIN/curl"

FETCH_OUTPUT="$TEST_ROOT/current-appcast.xml"
FETCH_KIND="$TEST_ROOT/current-appcast.kind"
FETCH_CALLED="$TEST_ROOT/curl-called"

fetch_first_feed_seed() {
  env \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CURL_STATUS="404" \
    MOCK_CURL_CALLED="$FETCH_CALLED" \
    "$FETCH_SCRIPT" \
      --output "$FETCH_OUTPUT" \
      --kind-output "$FETCH_KIND" \
      --version "0.1.3" \
      --build-number "4"
}

expect_success "exact first-feed identity accepts a versioned-feed 404" fetch_first_feed_seed
cmp "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" "$FETCH_OUTPUT" \
  || fail "first-feed bootstrap did not copy the byte-identical versioned seed"
[[ "$(<"$FETCH_KIND")" == "seed" ]] \
  || fail "first-feed bootstrap did not record seed provenance"
pass "first-feed bootstrap preserves versioned seed bytes and provenance"

rm -f "$FETCH_CALLED"
expect_failure_containing \
  "transition identity is rejected before network access" \
  "must be 0.1.3 or newer" \
  env \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CURL_STATUS="404" \
    MOCK_CURL_CALLED="$FETCH_CALLED" \
    "$FETCH_SCRIPT" \
      --output "$FETCH_OUTPUT" \
      --kind-output "$FETCH_KIND" \
      --version "0.1.2" \
      --build-number "3"
[[ ! -e "$FETCH_CALLED" ]] || fail "transition rejection occurred after network access"
pass "transition rejection is fail-fast"

expect_failure_containing \
  "future release cannot reset missing versioned-feed history" \
  "Refusing to reset signed history" \
  env \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CURL_STATUS="404" \
    MOCK_CURL_CALLED="$FETCH_CALLED" \
    "$FETCH_SCRIPT" \
      --output "$FETCH_OUTPUT" \
      --kind-output "$FETCH_KIND" \
      --version "0.1.4" \
      --build-number "5"

ARCHIVE_PATH="$TEST_ROOT/Ushot-0.1.3-arm64.zip"
NOTES_PATH="$TEST_ROOT/0.1.3.md"
printf 'archive-payload' > "$ARCHIVE_PATH"
printf 'Release notes' > "$NOTES_PATH"
ARCHIVE_LENGTH="$(stat -f '%z' "$ARCHIVE_PATH")"

write_appcast() {
  local output_path="$1"
  local forbidden_major_element="$2"
  cat > "$output_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- sparkle-sign-warning: generated test fixture -->
<!--
sparkle-signatures:
edSignature: QUJD
-->
<rss version="2.0" xmlns:sparkle="$USHOT_SPARKLE_XML_NAMESPACE">
  <channel>
    <title>$USHOT_APPCAST_CHANNEL_TITLE</title>
    <link>$USHOT_APPCAST_URL</link>
    <description>$USHOT_APPCAST_CHANNEL_DESCRIPTION</description>
    <language>$USHOT_APPCAST_CHANNEL_LANGUAGE</language>
    <item>
      <sparkle:version>4</sparkle:version>
      <sparkle:shortVersionString>0.1.3</sparkle:shortVersionString>
      $forbidden_major_element
      <description sparkle:format="markdown">Release notes</description>
      <enclosure url="https://github.com/isCheneycc/ushot/releases/download/v0.1.3/Ushot-0.1.3-arm64.zip" length="$ARCHIVE_LENGTH" type="application/octet-stream" sparkle:edSignature="QUJD" />
    </item>
  </channel>
</rss>
EOF
}

VALID_APPCAST="$TEST_ROOT/valid-appcast.xml"
MAJOR_APPCAST="$TEST_ROOT/major-appcast.xml"
WRONG_NAMESPACE_MAJOR_APPCAST="$TEST_ROOT/wrong-namespace-major-appcast.xml"
LEGACY_LINK_APPCAST="$TEST_ROOT/legacy-link-appcast.xml"
CONFLICTING_ENCLOSURE_IDENTITY_APPCAST="$TEST_ROOT/conflicting-enclosure-identity-appcast.xml"
write_appcast "$VALID_APPCAST" ''
write_appcast "$MAJOR_APPCAST" '<sparkle:minimumAutoupdateVersion>3</sparkle:minimumAutoupdateVersion>'
write_appcast "$WRONG_NAMESPACE_MAJOR_APPCAST" '<minimumAutoupdateVersion>3</minimumAutoupdateVersion>'
sed "s#$USHOT_APPCAST_URL#$USHOT_LEGACY_APPCAST_URL#" "$VALID_APPCAST" > "$LEGACY_LINK_APPCAST"
sed 's#<enclosure #<enclosure sparkle:version="999" sparkle:shortVersionString="9.9.9" #' \
  "$VALID_APPCAST" > "$CONFLICTING_ENCLOSURE_IDENTITY_APPCAST"

validate_fixture() {
  "$VALIDATE_SCRIPT" \
    --appcast "$1" \
    --archive "$ARCHIVE_PATH" \
    --release-notes "$NOTES_PATH" \
    --version "0.1.3" \
    --build-number "4" \
    --tag "v0.1.3"
}

expect_success "validator accepts an isolated feed item without a major-upgrade marker" validate_fixture "$VALID_APPCAST"
expect_failure_containing \
  "validator rejects sparkle:minimumAutoupdateVersion" \
  "must not be a major upgrade" \
  validate_fixture "$MAJOR_APPCAST"
expect_failure_containing \
  "validator rejects a minimumAutoupdateVersion in any namespace" \
  "must not be a major upgrade" \
  validate_fixture "$WRONG_NAMESPACE_MAJOR_APPCAST"
expect_failure_containing \
  "validator rejects the permanently absent legacy channel URL" \
  "unexpected versioned feed link" \
  validate_fixture "$LEGACY_LINK_APPCAST"
expect_failure_containing \
  "validator rejects conflicting enclosure version identity" \
  "version identity only in canonical Sparkle child elements" \
  validate_fixture "$CONFLICTING_ENCLOSURE_IDENTITY_APPCAST"

cat > "$MOCK_BIN/generate_appcast" <<'MOCK_GENERATE_APPCAST'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$@" > "${MOCK_GENERATE_ARGUMENTS:?}"
output_path=""
download_prefix=""
build_number=""
workspace=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account|--maximum-versions|--maximum-deltas|--ed-key-file)
      shift 2
      ;;
    --versions)
      build_number="${2:?}"
      shift 2
      ;;
    --download-url-prefix)
      download_prefix="${2:?}"
      shift 2
      ;;
    -o)
      output_path="${2:?}"
      shift 2
      ;;
    --embed-release-notes)
      shift
      ;;
    *)
      workspace="$1"
      shift
      ;;
  esac
done

[[ -n "$output_path" && -n "$download_prefix" && -n "$build_number" && -n "$workspace" ]]
archive_path="$(find "$workspace" -maxdepth 1 -type f -name 'Ushot-*-arm64.zip' -print | head -n 1)"
notes_path="$(find "$workspace" -maxdepth 1 -type f -name 'Ushot-*-arm64.md' -print | head -n 1)"
archive_name="$(basename "$archive_path")"
version="${archive_name#Ushot-}"
version="${version%-arm64.zip}"
archive_length="$(stat -f '%z' "$archive_path")"
notes="$(<"$notes_path")"

cat > "$output_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- sparkle-sign-warning: generated test fixture -->
<!--
sparkle-signatures:
edSignature: QUJD
-->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ushot Updates</title>
    <link>https://ischeneycc.github.io/ushot/updates/v1/appcast.xml</link>
    <description>Stable Ushot updates for macOS.</description>
    <language>en</language>
    <item>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <description sparkle:format="markdown">$notes</description>
      <enclosure url="$download_prefix$archive_name" length="$archive_length" type="application/octet-stream" sparkle:edSignature="QUJD" />
    </item>
  </channel>
</rss>
EOF
MOCK_GENERATE_APPCAST
chmod +x "$MOCK_BIN/generate_appcast"

cat > "$MOCK_BIN/sign_update" <<'MOCK_SIGN_UPDATE'
#!/bin/bash
exit 0
MOCK_SIGN_UPDATE
chmod +x "$MOCK_BIN/sign_update"

MOCK_GENERATE_ARGUMENTS="$TEST_ROOT/generate-arguments.txt"
run_seed_generation() {
  printf 'test-private-key\n' | \
    env MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.3" \
        --build-number "4" \
        --tag "v0.1.3" \
        --archive "$ARCHIVE_PATH" \
        --release-notes "$NOTES_PATH" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin"
}

expect_success "generator signs the exact first versioned-feed seed" run_seed_generation
if grep -Fxq -- '--major-version' "$MOCK_GENERATE_ARGUMENTS"; then
  fail "generate_appcast received forbidden --major-version"
fi
pass "generator does not emit a major-upgrade marker"
[[ -s "$SITE_DIRECTORY/$USHOT_APPCAST_RELATIVE_PATH" ]] \
  || fail "generator did not emit the canonical versioned Pages path"
[[ ! -e "$SITE_DIRECTORY/updates/appcast.xml" ]] \
  || fail "generator recreated the permanently absent legacy feed path"
pass "Pages payload contains only the versioned feed path"
validate_fixture "$SITE_DIRECTORY/$USHOT_APPCAST_RELATIVE_PATH" >/dev/null \
  || fail "generated appcast did not pass the independent validator"
pass "generated versioned appcast independently validates"

FUTURE_ARCHIVE="$TEST_ROOT/Ushot-0.1.4-arm64.zip"
FUTURE_NOTES="$TEST_ROOT/0.1.4.md"
printf 'future-archive' > "$FUTURE_ARCHIVE"
printf 'Future notes' > "$FUTURE_NOTES"

run_future_with_seed() {
  printf 'test-private-key\n' | \
    env MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FUTURE_ARCHIVE" \
        --release-notes "$FUTURE_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin"
}

expect_failure_containing \
  "generator rejects seed reuse after the first versioned feed" \
  "restricted to the exact first-feed identity" \
  run_future_with_seed

run_future_with_conflicting_retained_identity() {
  printf 'test-private-key\n' | \
    env MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FUTURE_ARCHIVE" \
        --release-notes "$FUTURE_NOTES" \
        --existing-appcast "$CONFLICTING_ENCLOSURE_IDENTITY_APPCAST" \
        --existing-appcast-kind "signed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin"
}

expect_failure_containing \
  "generator rejects retained enclosure version ambiguity" \
  "version identity only in canonical Sparkle child elements" \
  run_future_with_conflicting_retained_identity

SIGNED_EMPTY_APPCAST="$TEST_ROOT/signed-empty-appcast.xml"
cat > "$SIGNED_EMPTY_APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="$USHOT_SPARKLE_XML_NAMESPACE">
  <channel>
    <title>$USHOT_APPCAST_CHANNEL_TITLE</title>
    <link>$USHOT_APPCAST_URL</link>
    <description>$USHOT_APPCAST_CHANNEL_DESCRIPTION</description>
    <language>$USHOT_APPCAST_CHANNEL_LANGUAGE</language>
  </channel>
</rss>
EOF

run_future_with_empty_signed_history() {
  printf 'test-private-key\n' | \
    env MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FUTURE_ARCHIVE" \
        --release-notes "$FUTURE_NOTES" \
        --existing-appcast "$SIGNED_EMPTY_APPCAST" \
        --existing-appcast-kind "signed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin"
}

expect_failure_containing \
  "generator rejects a signed feed with reset history" \
  "must contain at least one retained release" \
  run_future_with_empty_signed_history

printf '1..%d\n' "$PASS_COUNT"
