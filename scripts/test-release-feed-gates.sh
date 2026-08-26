#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FETCH_SCRIPT="$SCRIPT_DIR/fetch-current-appcast.sh"
GENERATE_SCRIPT="$SCRIPT_DIR/generate-appcast.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-appcast.sh"
DERIVE_KEY_SCRIPT="$SCRIPT_DIR/derive-sparkle-public-key.swift"
KEY_RECOVERY_DRILL_SCRIPT="$SCRIPT_DIR/run-sparkle-key-recovery-drill.sh"
RELEASE_WORKFLOW="$PROJECT_ROOT/.github/workflows/release.yml"
CI_WORKFLOW="$PROJECT_ROOT/.github/workflows/ci.yml"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"
# shellcheck source=install-local.sh
source "$SCRIPT_DIR/install-local.sh"

mkdir -p "$PROJECT_ROOT/build"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ushot-feed-gates.XXXXXX")"
SITE_DIRECTORY="$(mktemp -d "$PROJECT_ROOT/build/test-release-feed-gates.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
SITE_DIRECTORY="$(cd "$SITE_DIRECTORY" && pwd -P)"
AUTHENTICATED_VALIDATOR_ROOT="$TEST_ROOT/authenticated-appcast-validator"
AUTHENTICATED_APPCAST_VALIDATOR="$AUTHENTICATED_VALIDATOR_ROOT/AuthenticatedAppcastValidator"
cleanup() {
  rm -rf "$TEST_ROOT" "$SITE_DIRECTORY"
}
trap cleanup EXIT

mkdir -p "$AUTHENTICATED_VALIDATOR_ROOT"
/usr/bin/xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  "$PROJECT_ROOT/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift" \
  "$PROJECT_ROOT/UshotCore/Sources/UshotCore/Update/UpdateChecking.swift" \
  "$PROJECT_ROOT/UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift" \
  "$PROJECT_ROOT/Tools/AuthenticatedAppcastValidator/main.swift" \
  -o "$AUTHENTICATED_APPCAST_VALIDATOR"
/usr/bin/codesign --force --sign - "$AUTHENTICATED_APPCAST_VALIDATOR" >/dev/null 2>&1
/usr/bin/codesign --verify --strict "$AUTHENTICATED_APPCAST_VALIDATOR"
AUTHENTICATED_APPCAST_VALIDATOR_SHA256="$(release_sha256 "$AUTHENTICATED_APPCAST_VALIDATOR")"
[[ "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || release_die "Could not bind the standalone authenticated-appcast validator."
export USHOT_AUTHENTICATED_APPCAST_VALIDATOR="$AUTHENTICATED_APPCAST_VALIDATOR"
export USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256="$AUTHENTICATED_APPCAST_VALIDATOR_SHA256"

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

assert_runtime_policy_requires_prebuilt_execution() {
  local function_body

  function_body="$(awk '
    /^release_validate_authenticated_appcast_runtime_policy\(\)/ { in_function = 1 }
    in_function { print }
    in_function && /^}/ { exit }
  ' "$SCRIPT_DIR/release-common.sh")"
  [[ -n "$function_body" ]]
  grep -Fq 'USHOT_AUTHENTICATED_APPCAST_VALIDATOR' <<< "$function_body"
  grep -Fq 'USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256' <<< "$function_body"
  ! grep -Eq '(^|[[:space:];|&])(swift|swiftc|xcrun)([[:space:];|&]|$)' \
    <<< "$function_body"
}

expect_success \
  "runtime appcast policy requires a prebuilt validator without implicit Swift compilation" \
  assert_runtime_policy_requires_prebuilt_execution

run_runtime_policy_without_prebuilt_validator() {
  env \
    -u USHOT_AUTHENTICATED_APPCAST_VALIDATOR \
    -u USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256 \
    /bin/bash -c '
      set -euo pipefail
      source "$1"
      release_validate_authenticated_appcast_runtime_policy "$2"
    ' runtime-policy-missing-validator \
      "$SCRIPT_DIR/release-common.sh" \
      "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH"
}

expect_failure_containing \
  "runtime appcast policy rejects a missing prebuilt validator" \
  "requires a prebuilt validator path and SHA-256" \
  run_runtime_policy_without_prebuilt_validator

run_runtime_policy_with_wrong_validator_digest() {
  env \
    USHOT_AUTHENTICATED_APPCAST_VALIDATOR="$AUTHENTICATED_APPCAST_VALIDATOR" \
    USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
    /bin/bash -c '
      set -euo pipefail
      source "$1"
      release_validate_authenticated_appcast_runtime_policy "$2"
    ' runtime-policy-wrong-validator-digest \
      "$SCRIPT_DIR/release-common.sh" \
      "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH"
}

expect_failure_containing \
  "runtime appcast policy rejects a changed prebuilt validator" \
  "checksum does not match the reviewed executable" \
  run_runtime_policy_with_wrong_validator_digest

assert_rollout_constants() {
  [[ "$USHOT_PUBLIC_UPDATE_BASELINE_VERSION" == "0.1.1" ]]
  [[ "$USHOT_PUBLIC_UPDATE_BASELINE_BUILD" == "2" ]]
  [[ "$USHOT_UPDATE_TRANSITION_VERSION" == "0.1.2" ]]
  [[ "$USHOT_UPDATE_TRANSITION_BUILD" == "3" ]]
  [[ "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" == "0.1.3" ]]
  [[ "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" == "4" ]]
  [[ "$USHOT_FIRST_FEED_VERSION" == "0.1.4" ]]
  [[ "$USHOT_FIRST_FEED_BUILD" == "5" ]]
  [[ "$USHOT_SCREEN_CAPTURE_KIT_WEAK_LINK_VERSION" == "0.1.7" ]]
  [[ "$USHOT_LEGACY_APPCAST_URL" == "https://ischeneycc.github.io/ushot/updates/appcast.xml" ]]
  [[ "$USHOT_LEGACY_APPCAST_RELATIVE_PATH" == "updates/appcast.xml" ]]
  [[ "$USHOT_APPCAST_RELATIVE_PATH" == "updates/v1/appcast.xml" ]]
  [[ "$USHOT_APPCAST_URL" == "https://ischeneycc.github.io/ushot/updates/v1/appcast.xml" ]]
  [[ "$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES" == "1048576" ]]
  [[ "$USHOT_SIGNED_APPCAST_TRAILER_ALLOWANCE_BYTES" == "512" ]]
  [[ "$USHOT_MAX_SIGNED_APPCAST_BYTES" == "1049088" ]]
  [[ "$USHOT_SPARKLE_KEY_ACCOUNT" == "io.github.ischeneycc.ushot.20260806" ]]
  [[ "$USHOT_SPARKLE_PUBLIC_ED_KEY" == "+zRL11/2yYePt5O+OetThnLGwyvAvFtPPXxiBBOTTjE=" ]]
  [[ "$USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY" == "gdZAswkBeWYGYjpqCUmtrUEuyIc/RP5DO+c5I7h+h3Q=" ]]
  [[ "$USHOT_SPARKLE_PUBLIC_ED_KEY" != "$USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY" ]]
  [[ -s "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" ]]
  [[ ! -e "$PROJECT_ROOT/$USHOT_LEGACY_APPCAST_RELATIVE_PATH" ]]
  release_validate_update_rollout_constants
  release_validate_feed_release_identity "0.1.4" "5"
  release_validate_feed_release_identity "0.1.5" "6"
}

reject_transition_feed() {
  release_validate_feed_release_identity "0.1.3" "4"
}

expect_success "rollout identities and versioned feed path are canonical" assert_rollout_constants
expect_failure_containing \
  "transition release cannot publish a feed" \
  "must be 0.1.4 or newer" \
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

OPENSSL_HEADER_FIXTURE="$TEST_ROOT/openssl-salted-header.enc"

create_and_validate_openssl_header_fixture() {
  printf 'public Ushot encrypted-header fixture' \
    | /usr/bin/openssl enc \
        -aes-256-cbc \
        -salt \
        -pbkdf2 \
        -iter 600000 \
        -md sha256 \
        -pass fd:3 \
        -out "$OPENSSL_HEADER_FIXTURE" \
        3< <(printf '%s' 'public-test-password-only')
  chmod 600 "$OPENSSL_HEADER_FIXTURE"
  release_validate_openssl_salted_ciphertext "$OPENSSL_HEADER_FIXTURE"
}

assert_backup_helpers_share_header_validation() {
  [[ "$(grep -Fc 'release_validate_openssl_salted_ciphertext "$ENCRYPTED_BACKUP"' \
      "$SCRIPT_DIR/backup-sparkle-key.sh")" == "1" ]]
  [[ "$(grep -Fc 'release_validate_openssl_salted_ciphertext "$CANONICAL_BACKUP"' \
      "$SCRIPT_DIR/run-sparkle-key-recovery-drill.sh")" == "1" ]]
  ! grep -Fq '/usr/bin/dd' "$SCRIPT_DIR/backup-sparkle-key.sh"
}

expect_success \
  "encrypted-backup validator accepts real macOS OpenSSL salted output" \
  create_and_validate_openssl_header_fixture
expect_success \
  "backup and recovery helpers share the fail-closed header validator" \
  assert_backup_helpers_share_header_validation

KEY_DRILL_FIXTURES_ROOT="$(cd "$TEST_ROOT" && pwd -P)/key-drill-fixtures"
KEY_DRILL_MOCK_ROOT="$KEY_DRILL_FIXTURES_ROOT/mock-scripts"
KEY_DRILL_TRACE="$KEY_DRILL_FIXTURES_ROOT/downstream.trace"
KEY_DRILL_ASSETS="$KEY_DRILL_FIXTURES_ROOT/assets"
mkdir -p "$KEY_DRILL_MOCK_ROOT" "$KEY_DRILL_ASSETS"

/usr/bin/sed \
  's#/usr/bin/openssl#"$SCRIPT_DIR/openssl-mock.sh"#g' \
  "$KEY_RECOVERY_DRILL_SCRIPT" \
  > "$KEY_DRILL_MOCK_ROOT/run-sparkle-key-recovery-drill.sh"
chmod +x "$KEY_DRILL_MOCK_ROOT/run-sparkle-key-recovery-drill.sh"
cp "$SCRIPT_DIR/release-common.sh" "$KEY_DRILL_MOCK_ROOT/release-common.sh"

cat > "$KEY_DRILL_MOCK_ROOT/validate-release-assets.sh" <<'MOCK_VALIDATE_ASSETS'
#!/bin/bash
printf 'asset-validation\n' >> "${KEY_DRILL_TEST_TRACE:?}"
exit 97
MOCK_VALIDATE_ASSETS

cat > "$KEY_DRILL_MOCK_ROOT/download-sparkle-tools.sh" <<'MOCK_DOWNLOAD_TOOLS'
#!/bin/bash
printf 'tool-download\n' >> "${KEY_DRILL_TEST_TRACE:?}"
exit 98
MOCK_DOWNLOAD_TOOLS

cat > "$KEY_DRILL_MOCK_ROOT/openssl-mock.sh" <<'MOCK_OPENSSL'
#!/bin/bash
printf 'password-prompt\n' >> "${KEY_DRILL_TEST_TRACE:?}"
exit 99
MOCK_OPENSSL
chmod +x \
  "$KEY_DRILL_MOCK_ROOT/validate-release-assets.sh" \
  "$KEY_DRILL_MOCK_ROOT/download-sparkle-tools.sh" \
  "$KEY_DRILL_MOCK_ROOT/openssl-mock.sh"

VALID_KEY_BACKUP="$KEY_DRILL_FIXTURES_ROOT/valid-key.backup.enc"
printf 'Salted__fixture-ciphertext' > "$VALID_KEY_BACKUP"
chmod 600 "$VALID_KEY_BACKUP"
VALID_KEY_BACKUP_SHA256="$(release_sha256 "$VALID_KEY_BACKUP")"

expect_key_drill_preflight_failure() {
  local name="$1"
  local expected="$2"
  local backup_path="$3"
  local expected_digest="$4"
  local output
  local status

  : > "$KEY_DRILL_TRACE"
  set +e
  output="$(
    KEY_DRILL_TEST_TRACE="$KEY_DRILL_TRACE" \
      "$KEY_DRILL_MOCK_ROOT/run-sparkle-key-recovery-drill.sh" \
        --backup "$backup_path" \
        --expected-backup-sha256 "$expected_digest" \
        --assets-directory "$KEY_DRILL_ASSETS" \
        2>&1
  )"
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
  [[ ! -s "$KEY_DRILL_TRACE" ]] || {
    printf 'unexpected downstream calls:\n%s\n' "$(<"$KEY_DRILL_TRACE")" >&2
    fail "$name reached asset validation, tool download, or the password prompt"
  }
  pass "$name"
}

expect_key_drill_preflight_failure \
  "key drill rejects a relative backup before downstream work" \
  "Encrypted backup path must be absolute." \
  "relative-key.backup.enc" \
  "$VALID_KEY_BACKUP_SHA256"

NONCANONICAL_KEY_BACKUP="$KEY_DRILL_FIXTURES_ROOT/../key-drill-fixtures/valid-key.backup.enc"
expect_key_drill_preflight_failure \
  "key drill rejects a noncanonical backup before downstream work" \
  "must not traverse symbolic links" \
  "$NONCANONICAL_KEY_BACKUP" \
  "$VALID_KEY_BACKUP_SHA256"

SYMLINK_KEY_BACKUP="$KEY_DRILL_FIXTURES_ROOT/symlink-key.backup.enc"
ln -s "$VALID_KEY_BACKUP" "$SYMLINK_KEY_BACKUP"
expect_key_drill_preflight_failure \
  "key drill rejects a backup symlink before downstream work" \
  "regular, non-symbolic-link file" \
  "$SYMLINK_KEY_BACKUP" \
  "$VALID_KEY_BACKUP_SHA256"

BAD_MODE_KEY_BACKUP="$KEY_DRILL_FIXTURES_ROOT/bad-mode-key.backup.enc"
printf 'Salted__fixture-ciphertext' > "$BAD_MODE_KEY_BACKUP"
chmod 640 "$BAD_MODE_KEY_BACKUP"
expect_key_drill_preflight_failure \
  "key drill rejects unsafe backup permissions before downstream work" \
  "permissions must be exactly 0600" \
  "$BAD_MODE_KEY_BACKUP" \
  "$(release_sha256 "$BAD_MODE_KEY_BACKUP")"

expect_key_drill_preflight_failure \
  "key drill rejects an unrecorded backup digest before downstream work" \
  "does not match the independently recorded value" \
  "$VALID_KEY_BACKUP" \
  "0000000000000000000000000000000000000000000000000000000000000000"

BAD_HEADER_KEY_BACKUP="$KEY_DRILL_FIXTURES_ROOT/bad-header-key.backup.enc"
printf 'NotSalted-fixture-ciphertext' > "$BAD_HEADER_KEY_BACKUP"
chmod 600 "$BAD_HEADER_KEY_BACKUP"
expect_key_drill_preflight_failure \
  "key drill rejects a non-OpenSSL backup before downstream work" \
  "missing the OpenSSL Salted__ header" \
  "$BAD_HEADER_KEY_BACKUP" \
  "$(release_sha256 "$BAD_HEADER_KEY_BACKUP")"

PREFLIGHT_ROOT="$TEST_ROOT/preflight-repository"
mkdir -p \
  "$PREFLIGHT_ROOT/Config" \
  "$PREFLIGHT_ROOT/scripts" \
  "$PREFLIGHT_ROOT/UshotApp" \
  "$PREFLIGHT_ROOT/UshotCore/Sources/UshotCore/Product" \
  "$PREFLIGHT_ROOT/updates/release-notes" \
  "$PREFLIGHT_ROOT/updates/v1"
cp "$SCRIPT_DIR/release-common.sh" "$PREFLIGHT_ROOT/scripts/release-common.sh"
cp "$SCRIPT_DIR/release-preflight.sh" "$PREFLIGHT_ROOT/scripts/release-preflight.sh"
cp "$PROJECT_ROOT/Config/Debug.xcconfig" "$PREFLIGHT_ROOT/Config/Debug.xcconfig"
cp "$PROJECT_ROOT/Config/Release.xcconfig" "$PREFLIGHT_ROOT/Config/Release.xcconfig"
cp "$PROJECT_ROOT/UshotApp/Info.plist" "$PREFLIGHT_ROOT/UshotApp/Info.plist"
cp "$DERIVE_KEY_SCRIPT" "$PREFLIGHT_ROOT/scripts/derive-sparkle-public-key.swift"
cp \
  "$PROJECT_ROOT/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift" \
  "$PREFLIGHT_ROOT/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift"
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
REGISTER_WITH_LAUNCH_SERVICES = NO
SPARKLE_KEY_ACCOUNT = io.github.ischeneycc.ushot.20260806
SPARKLE_PUBLIC_ED_KEY = $USHOT_SPARKLE_PUBLIC_ED_KEY
LD_RUNPATH_SEARCH_PATHS = \$(inherited) @executable_path/../Frameworks
OTHER_LDFLAGS = \$(inherited) -weak_framework ScreenCaptureKit
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

cp "$PREFLIGHT_ROOT/Config/Debug.xcconfig" "$PREFLIGHT_ROOT/Config/Debug.xcconfig.valid"
/usr/bin/sed -i '' \
  "s/$USHOT_DEBUG_BUNDLE_IDENTIFIER/$USHOT_BUNDLE_IDENTIFIER/" \
  "$PREFLIGHT_ROOT/Config/Debug.xcconfig"
expect_failure_containing \
  "source gate rejects a Debug build that reuses the production identity" \
  "Debug APP_BUNDLE_IDENTIFIER must be isolated" \
  release_validate_source_settings \
  "$PREFLIGHT_ROOT" \
  "0.1.3" \
  "4"
mv "$PREFLIGHT_ROOT/Config/Debug.xcconfig.valid" "$PREFLIGHT_ROOT/Config/Debug.xcconfig"

INSTALL_REGISTRATION_ROOT="$TEST_ROOT/local-install-registration"
mkdir -p "$INSTALL_REGISTRATION_ROOT/Ushot.app/Contents/MacOS"
printf '#!/bin/bash\nexit 0\n' > "$INSTALL_REGISTRATION_ROOT/Ushot.app/Contents/MacOS/Ushot"
chmod +x "$INSTALL_REGISTRATION_ROOT/Ushot.app/Contents/MacOS/Ushot"

registration_precedes_launch() (
  local order_log="$INSTALL_REGISTRATION_ROOT/success-order.log"
  DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/Ushot.app"
  DESTINATION_EXECUTABLE="$DESTINATION_APP/Contents/MacOS/Ushot"
  LEGACY_DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/UshotApp.app"
  invoke_launch_services_registration() {
    printf '%s\n' register >> "$order_log"
  }
  launch_services_contains_exact_path() {
    return 0
  }
  launch_exact_app() {
    printf '%s\n' launch >> "$order_log"
  }
  register_and_launch_installed_app \
    "$DESTINATION_APP" \
    "$DESTINATION_EXECUTABLE" \
    "$(release_file_id "$DESTINATION_APP")" \
    "$(release_inode "$DESTINATION_EXECUTABLE")" \
    "test Ushot"
  [[ "$(<"$order_log")" == $'register\nlaunch' ]]
)

registration_failure_blocks_launch() (
  local order_log="$INSTALL_REGISTRATION_ROOT/failure-order.log"
  DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/Ushot.app"
  DESTINATION_EXECUTABLE="$DESTINATION_APP/Contents/MacOS/Ushot"
  LEGACY_DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/UshotApp.app"
  invoke_launch_services_registration() {
    printf '%s\n' register >> "$order_log"
    return 1
  }
  launch_exact_app() {
    printf '%s\n' launch >> "$order_log"
  }
  if register_and_launch_installed_app \
      "$DESTINATION_APP" \
      "$DESTINATION_EXECUTABLE" \
      "$(release_file_id "$DESTINATION_APP")" \
      "$(release_inode "$DESTINATION_EXECUTABLE")" \
      "test Ushot"; then
    return 1
  fi
  [[ "$(<"$order_log")" == "register" ]]
)

registration_rejects_changed_identity() (
  local invocation_log="$INSTALL_REGISTRATION_ROOT/changed-identity.log"
  DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/Ushot.app"
  DESTINATION_EXECUTABLE="$DESTINATION_APP/Contents/MacOS/Ushot"
  LEGACY_DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/UshotApp.app"
  invoke_launch_services_registration() {
    printf '%s\n' invoked >> "$invocation_log"
  }
  if register_exact_installed_app \
      "$DESTINATION_APP" \
      "$DESTINATION_EXECUTABLE" \
      "$(release_file_id "$DESTINATION_APP")" \
      "999999999" \
      "test Ushot"; then
    return 1
  fi
  [[ ! -e "$invocation_log" ]]
)

registration_requires_retained_exact_path() (
  DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/Ushot.app"
  DESTINATION_EXECUTABLE="$DESTINATION_APP/Contents/MacOS/Ushot"
  LEGACY_DESTINATION_APP="$INSTALL_REGISTRATION_ROOT/UshotApp.app"
  invoke_launch_services_registration() {
    return 0
  }
  launch_services_contains_exact_path() {
    return 1
  }
  if register_exact_installed_app \
      "$DESTINATION_APP" \
      "$DESTINATION_EXECUTABLE" \
      "$(release_file_id "$DESTINATION_APP")" \
      "$(release_inode "$DESTINATION_EXECUTABLE")" \
      "test Ushot"; then
    return 1
  fi
)

rollback_restart_requires_verified_registration() (
  local launch_log="$INSTALL_REGISTRATION_ROOT/unverified-restart.log"

  launch_exact_app() {
    printf '%s\n' launch >> "$launch_log"
  }
  if restart_previous_app_if_needed \
      "YES" \
      "$INSTALL_REGISTRATION_ROOT/Ushot.app" \
      "$INSTALL_REGISTRATION_ROOT/Ushot.app/Contents/MacOS/Ushot" \
      "test Ushot" \
      "12345" \
      "NO"; then
    return 1
  fi
  [[ ! -e "$launch_log" ]]
)

rollback_registration_failure_blocks_restored_restart() (
  local rollback_root="$INSTALL_REGISTRATION_ROOT/rollback-registration-failure"
  local registration_log="$rollback_root/registration.log"
  local launch_log="$rollback_root/launch.log"

  mkdir -p \
    "$rollback_root/backup/Ushot.app.backup/Contents/MacOS"
  printf '#!/bin/bash\nexit 0\n' \
    > "$rollback_root/backup/Ushot.app.backup/Contents/MacOS/Ushot"
  chmod +x "$rollback_root/backup/Ushot.app.backup/Contents/MacOS/Ushot"

  DESTINATION_APP="$rollback_root/Ushot.app"
  DESTINATION_EXECUTABLE="$DESTINATION_APP/Contents/MacOS/Ushot"
  LEGACY_DESTINATION_APP="$rollback_root/UshotApp.app"
  LEGACY_DESTINATION_EXECUTABLE="$LEGACY_DESTINATION_APP/Contents/MacOS/UshotApp"
  BACKUP_ROOT="$rollback_root/backup"
  BACKUP_ROOT_FILE_ID="$(release_file_id "$BACKUP_ROOT")"
  CURRENT_BACKUP_APP="$BACKUP_ROOT/Ushot.app.backup"
  LEGACY_BACKUP_APP="$BACKUP_ROOT/UshotApp.app.backup"
  FAILED_NEW_BACKUP_APP=""
  STAGING_ROOT=""
  STAGED_APP=""
  STAGED_FILE_ID=""
  STAGED_EXECUTABLE_INODE=""
  SOURCE_VERSION="0.1.10"
  SOURCE_BUILD="11"
  SOURCE_TEAM="TESTTEAM01"
  SOURCE_REQUIREMENT="replacement requirement"
  SOURCE_BINARY_SHA="replacement sha"
  CURRENT_ORIGINAL_FILE_ID="$(release_file_id "$CURRENT_BACKUP_APP")"
  CURRENT_ORIGINAL_EXECUTABLE_INODE="$(release_inode "$CURRENT_BACKUP_APP/Contents/MacOS/Ushot")"
  CURRENT_ORIGINAL_REQUIREMENT="previous requirement"
  LEGACY_ORIGINAL_FILE_ID=""
  LEGACY_ORIGINAL_EXECUTABLE_INODE=""
  LEGACY_ORIGINAL_REQUIREMENT=""
  CURRENT_WAS_RUNNING="YES"
  LEGACY_WAS_RUNNING="NO"
  PROCESS_SHUTDOWN_BEGAN="YES"
  CURRENT_MOVE_BEGAN="YES"
  LEGACY_MOVE_BEGAN="NO"
  NEW_MOVE_BEGAN="NO"
  CURRENT_MOVED="YES"
  LEGACY_MOVED="NO"
  NEW_INSTALLED="NO"
  INSTALL_LOCK_HELD="NO"

  validate_current_recovery_app() {
    return 0
  }
  register_exact_installed_app() {
    printf '%s\n' register >> "$registration_log"
    return 1
  }
  launch_exact_app() {
    printf '%s\n' launch >> "$launch_log"
  }

  if rollback_install; then
    return 1
  fi
  [[ -d "$DESTINATION_APP" \
      && "$(<"$registration_log")" == "register" \
      && ! -e "$launch_log" ]]
)

rollback_unregisters_failed_first_install() (
  local rollback_root="$INSTALL_REGISTRATION_ROOT/rollback-first-install"
  local registration_log="$rollback_root/registration-order.log"
  local registered_state="YES"

  mkdir -p "$rollback_root/Ushot.app/Contents/MacOS" "$rollback_root/backup"
  printf '#!/bin/bash\nexit 0\n' > "$rollback_root/Ushot.app/Contents/MacOS/Ushot"
  chmod +x "$rollback_root/Ushot.app/Contents/MacOS/Ushot"

  DESTINATION_APP="$rollback_root/Ushot.app"
  DESTINATION_EXECUTABLE="$DESTINATION_APP/Contents/MacOS/Ushot"
  LEGACY_DESTINATION_APP="$rollback_root/UshotApp.app"
  LEGACY_DESTINATION_EXECUTABLE="$LEGACY_DESTINATION_APP/Contents/MacOS/UshotApp"
  BACKUP_ROOT="$rollback_root/backup"
  BACKUP_ROOT_FILE_ID="$(release_file_id "$BACKUP_ROOT")"
  CURRENT_BACKUP_APP="$BACKUP_ROOT/Ushot.app"
  LEGACY_BACKUP_APP="$BACKUP_ROOT/UshotApp.app"
  FAILED_NEW_BACKUP_APP=""
  STAGING_ROOT=""
  STAGED_APP=""
  STAGED_FILE_ID="$(release_file_id "$DESTINATION_APP")"
  STAGED_EXECUTABLE_INODE="$(release_inode "$DESTINATION_EXECUTABLE")"
  SOURCE_VERSION="0.1.9"
  SOURCE_BUILD="10"
  SOURCE_TEAM="TESTTEAM01"
  SOURCE_REQUIREMENT="test requirement"
  SOURCE_BINARY_SHA="test sha"
  CURRENT_ORIGINAL_FILE_ID=""
  CURRENT_ORIGINAL_EXECUTABLE_INODE=""
  CURRENT_ORIGINAL_REQUIREMENT=""
  LEGACY_ORIGINAL_FILE_ID=""
  LEGACY_ORIGINAL_EXECUTABLE_INODE=""
  LEGACY_ORIGINAL_REQUIREMENT=""
  CURRENT_MOVE_BEGAN="NO"
  LEGACY_MOVE_BEGAN="NO"
  NEW_MOVE_BEGAN="NO"
  CURRENT_MOVED="NO"
  LEGACY_MOVED="NO"
  NEW_INSTALLED="YES"
  PROCESS_SHUTDOWN_BEGAN="NO"
  INSTALL_LOCK_HELD="NO"

  validate_replacement_recovery_app() {
    return 0
  }
  stop_exact_executable() {
    return 0
  }
  launch_services_contains_exact_path() {
    [[ "$registered_state" == "YES" ]]
  }
  invoke_launch_services_unregistration() {
    [[ "$1" == "$DESTINATION_APP" && -d "$DESTINATION_APP" ]] || return 1
    printf '%s\n' unregister >> "$registration_log"
    registered_state="NO"
  }

  rollback_install
  [[ "$registered_state" == "NO" \
      && "$(<"$registration_log")" == "unregister" \
      && ! -e "$DESTINATION_APP" \
      && -d "$BACKUP_ROOT/Ushot-failed-install.app.backup" ]]
)

expect_success \
  "local installer registers the exact final app before launch" \
  registration_precedes_launch
expect_success \
  "local installer blocks launch when LaunchServices registration fails" \
  registration_failure_blocks_launch
expect_success \
  "local installer refuses registration after executable identity changes" \
  registration_rejects_changed_identity
expect_success \
  "local installer verifies that LaunchServices retained the exact registered path" \
  registration_requires_retained_exact_path
expect_success \
  "rollback restart requires verified exact LaunchServices registration" \
  rollback_restart_requires_verified_registration
expect_success \
  "rollback registration failure blocks restart of the restored app" \
  rollback_registration_failure_blocks_restored_restart
expect_success \
  "first-install rollback unregisters a failed replacement before moving it" \
  rollback_unregisters_failed_first_install
grep -F \
  '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister' \
  "$SCRIPT_DIR/install-local.sh" >/dev/null \
  || fail "local installer must call the fixed system LaunchServices registrar"
pass "local installer pins the system LaunchServices registrar path"
grep -F 'CURRENT_BACKUP_APP="$BACKUP_ROOT/$USHOT_APP_BUNDLE.backup"' \
  "$SCRIPT_DIR/install-local.sh" >/dev/null \
  || fail "local installer must preserve recoverable app bundles outside LaunchServices-discoverable .app paths"
[[ "$(grep -Fc 'unregister_exact_installed_app \' "$SCRIPT_DIR/install-local.sh")" == "3" ]] \
  || fail "local installer must unregister current, legacy and failed replacement backup paths"
pass "local installer keeps recoverable backups out of LaunchServices attribution"
[[ "$(grep -Fc 'unregister_disposable_build_product "$BUILT_APP"' "$SCRIPT_DIR/build-release.sh")" == "1" \
    && "$(grep -Fc 'unregister_disposable_build_product "$OUTPUT_APP"' "$SCRIPT_DIR/build-release.sh")" == "1" ]] \
  || fail "release build must unregister both disposable production-identity app paths"
pass "release build unregisters disposable production-identity app paths"
grep -F 'if ! launch_services_contains_exact_path "$app_path"; then' \
  "$SCRIPT_DIR/build-release.sh" >/dev/null \
  || fail "release build must distinguish an unregistered disposable app from an unregister failure"
grep -F 'if launch_services_contains_exact_path "$app_path"; then' \
  "$SCRIPT_DIR/build-release.sh" >/dev/null \
  || fail "release build must verify that a disposable app is absent after unregistering it"
pass "release build verifies disposable LaunchServices cleanup without treating absence as failure"

/usr/bin/sed -i '' \
  "s#$USHOT_SPARKLE_PUBLIC_ED_KEY#$USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY#" \
  "$PREFLIGHT_ROOT/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift"
git -C "$PREFLIGHT_ROOT" add .
git -C "$PREFLIGHT_ROOT" commit -qm "test: mismatched ProductIdentity key"
git -C "$PREFLIGHT_ROOT" tag -f "v0.1.3" >/dev/null

expect_failure_containing \
  "release preflight rejects a mismatched ProductIdentity key" \
  "ProductIdentity sparklePublicEDKey does not match" \
  run_versioned_preflight

cp \
  "$PROJECT_ROOT/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift" \
  "$PREFLIGHT_ROOT/UshotCore/Sources/UshotCore/Product/ProductIdentity.swift"
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
    if [[ -n "${MOCK_SCREEN_CAPTURE_KIT_STRONG_FRAMEWORK:-}" ]]; then
      printf '%s\n' '/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit (compatibility version 1.0.0, current version 1.0.0)'
    else
      printf '%s\n' '/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit (compatibility version 1.0.0, current version 1.0.0, weak)'
      if [[ -n "${MOCK_SCREEN_CAPTURE_KIT_DUPLICATE_FRAMEWORK:-}" ]]; then
        printf '%s\n' '/System/Library/Frameworks/ScreenCaptureKit.framework/Versions/A/ScreenCaptureKit (compatibility version 1.0.0, current version 1.0.0)'
      fi
    fi
    ;;
  -l)
    printf '%s\n' 'cmd LC_RPATH' 'path @executable_path/../Frameworks (offset 12)'
    ;;
  *)
    exit 1
    ;;
esac
MOCK_OTOOL
cat > "$APP_MOCK_BIN/nm" <<'MOCK_NM'
#!/bin/bash
set -euo pipefail
linkage='weak external'
if [[ -n "${MOCK_SCREEN_CAPTURE_KIT_STRONG_CLASS:-}" ]]; then
  linkage='external'
fi
printf '%s\n' \
  "                 (undefined) $linkage _OBJC_CLASS_\$_SCScreenshotConfiguration (from ScreenCaptureKit)" \
  "                 (undefined) $linkage _OBJC_CLASS_\$_SCScreenshotOutput (from ScreenCaptureKit)"
MOCK_NM
cat > "$APP_MOCK_BIN/xcrun" <<'MOCK_XCRUN'
#!/bin/bash
set -euo pipefail
[[ "${1:-}" == "dyld_info" ]] || exit 1
case "${2:-}" in
  -imports|-fixups) ;;
  *) exit 1 ;;
esac
marker=' [weak-import]'
if [[ -n "${MOCK_SCREEN_CAPTURE_KIT_STRONG_DYLD:-}" ]]; then
  marker=''
fi
printf '%s\n' \
  "ScreenCaptureKit/_OBJC_CLASS_\$_SCScreenshotConfiguration$marker" \
  "ScreenCaptureKit/_OBJC_CLASS_\$_SCScreenshotOutput$marker"
MOCK_XCRUN
chmod +x "$APP_MOCK_BIN/otool" "$APP_MOCK_BIN/nm" "$APP_MOCK_BIN/xcrun"
printf '#!/bin/bash\nexit 0\n' > "$TEST_APP/Contents/MacOS/Ushot"
printf '#!/bin/bash\nexit 0\n' > "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
chmod +x \
  "$TEST_APP/Contents/MacOS/Ushot" \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
printf 'notices' > "$TEST_APP/Contents/Resources/ThirdPartyNotices.txt"
printf 'license' > "$TEST_APP/Contents/Resources/LICENSE"
printf 'icon' > "$TEST_APP/Contents/Resources/AppIcon.icns"
printf 'assets' > "$TEST_APP/Contents/Resources/Assets.car"
cat > "$TEST_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$USHOT_BUNDLE_IDENTIFIER</string>
  <key>CFBundleDisplayName</key><string>$USHOT_PRODUCT_NAME</string>
  <key>CFBundleName</key><string>$USHOT_PRODUCT_NAME</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>$USHOT_EXECUTABLE_NAME</string>
  <key>CFBundleShortVersionString</key><string>0.1.3</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>SUFeedURL</key><string>$USHOT_APPCAST_URL</string>
  <key>SUPublicEDKey</key><string>$USHOT_SPARKLE_PUBLIC_ED_KEY</string>
  <key>SURequireSignedFeed</key><true/>
  <key>SURequireExactUpdateVersionIdentity</key><true/>
  <key>SURequireEdDSAUpdateArchiveSignature</key><true/>
  <key>SURequireHostSignedAppcastValidation</key><true/>
  <key>SUMaximumSignedAppcastContentLength</key><integer>$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES</integer>
  <key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SUEnableSystemProfiling</key><false/>
</dict></plist>
EOF
cat > "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$USHOT_SIGNED_FEED_VALIDATION_SPARKLE_VERSION</string>
  <key>CFBundleVersion</key><string>$USHOT_SIGNED_FEED_VALIDATION_SPARKLE_BUILD</string>
  <key>SUUpdateVersionIdentityHardeningVersion</key><integer>1</integer>
  <key>SUHostSignedAppcastValidationVersion</key><integer>1</integer>
  <key>SUFeedDownloadSizeLimitVersion</key><integer>1</integer>
</dict></plist>
EOF

validate_hardened_app() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity "$TEST_APP" "0.1.3" "4"
}

expect_success "built-app gate accepts host requirements and all framework markers" validate_hardened_app
DISPLAY_IDENTITY_BOUNDARY_APP="$TEST_ROOT/display-identity-boundary/Ushot.app"
mkdir -p "$(dirname "$DISPLAY_IDENTITY_BOUNDARY_APP")"
cp -R "$TEST_APP" "$DISPLAY_IDENTITY_BOUNDARY_APP"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleDisplayName' \
  "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' \
  "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' \
  "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Info.plist"
rm "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Resources/AppIcon.icns"
rm "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Resources/Assets.car"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.9' \
  "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 10' \
  "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Info.plist"
validate_legacy_display_identity_boundary() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity \
    "$DISPLAY_IDENTITY_BOUNDARY_APP" \
    "0.1.9" \
    "10"
}
expect_success \
  "built-app gate preserves 0.1.9 compatibility without newer display metadata" \
  validate_legacy_display_identity_boundary
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.10' \
  "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 11' \
  "$DISPLAY_IDENTITY_BOUNDARY_APP/Contents/Info.plist"
validate_current_display_identity_boundary() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity \
    "$DISPLAY_IDENTITY_BOUNDARY_APP" \
    "0.1.10" \
    "11"
}
expect_failure_containing \
  "built-app gate requires display metadata beginning with 0.1.10" \
  "Missing CFBundleDisplayName" \
  validate_current_display_identity_boundary
RECOVERY_NAME_TEST_APP="$TEST_ROOT/Ushot.app.backup"
cp -R "$TEST_APP" "$RECOVERY_NAME_TEST_APP"
validate_explicit_recovery_bundle_name() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity \
    "$RECOVERY_NAME_TEST_APP" \
    "0.1.3" \
    "4" \
    "Ushot.app.backup"
}
validate_ordinary_recovery_bundle_name() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity \
    "$RECOVERY_NAME_TEST_APP" \
    "0.1.3" \
    "4"
}
expect_success \
  "built-app gate accepts the explicit installer recovery suffix" \
  validate_explicit_recovery_bundle_name
expect_failure_containing \
  "ordinary built-app validation still rejects the installer recovery suffix" \
  "Release product must be named Ushot.app" \
  validate_ordinary_recovery_bundle_name
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Ushot.app' "$TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "built-app gate rejects a fallback-style display name" \
  "unexpected display name" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $USHOT_PRODUCT_NAME" "$TEST_APP/Contents/Info.plist"
rm "$TEST_APP/Contents/Resources/AppIcon.icns"
ln -s missing.icns "$TEST_APP/Contents/Resources/AppIcon.icns"
expect_failure_containing \
  "built-app gate rejects a symbolic or missing application icon" \
  "nonempty regular AppIcon.icns" \
  validate_hardened_app
rm "$TEST_APP/Contents/Resources/AppIcon.icns"
printf 'icon' > "$TEST_APP/Contents/Resources/AppIcon.icns"
: > "$TEST_APP/Contents/Resources/Assets.car"
expect_failure_containing \
  "built-app gate rejects an empty compiled asset catalog" \
  "nonempty regular Assets.car" \
  validate_hardened_app
printf 'assets' > "$TEST_APP/Contents/Resources/Assets.car"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.7' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 8' "$TEST_APP/Contents/Info.plist"
validate_weak_linked_capture_app() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity "$TEST_APP" "0.1.7" "8"
}
validate_strong_framework_capture_app() {
  MOCK_SCREEN_CAPTURE_KIT_STRONG_FRAMEWORK=1 \
    PATH="$APP_MOCK_BIN:$PATH" \
    release_validate_app_identity "$TEST_APP" "0.1.7" "8"
}
validate_duplicate_framework_capture_app() {
  MOCK_SCREEN_CAPTURE_KIT_DUPLICATE_FRAMEWORK=1 \
    PATH="$APP_MOCK_BIN:$PATH" \
    release_validate_app_identity "$TEST_APP" "0.1.7" "8"
}
validate_strong_class_capture_app() {
  MOCK_SCREEN_CAPTURE_KIT_STRONG_CLASS=1 \
    PATH="$APP_MOCK_BIN:$PATH" \
    release_validate_app_identity "$TEST_APP" "0.1.7" "8"
}
validate_strong_dyld_capture_app() {
  MOCK_SCREEN_CAPTURE_KIT_STRONG_DYLD=1 \
    PATH="$APP_MOCK_BIN:$PATH" \
    release_validate_app_identity "$TEST_APP" "0.1.7" "8"
}
expect_success \
  "built-app gate accepts weak-linked macOS 26 ScreenCaptureKit classes" \
  validate_weak_linked_capture_app
expect_failure_containing \
  "built-app gate rejects strong-linked macOS 26 ScreenCaptureKit classes" \
  "must weak-link ScreenCaptureKit" \
  validate_strong_framework_capture_app
expect_failure_containing \
  "built-app gate rejects mixed weak and strong ScreenCaptureKit load commands" \
  "must weak-link ScreenCaptureKit" \
  validate_duplicate_framework_capture_app
expect_failure_containing \
  "built-app gate rejects strong-imported macOS 26 ScreenCaptureKit classes" \
  "must weak-import macOS 26 ScreenCaptureKit class" \
  validate_strong_class_capture_app
expect_failure_containing \
  "built-app gate rejects a non-weak dyld fixup for macOS 26 ScreenCaptureKit classes" \
  "dyld -imports must mark macOS 26 class" \
  validate_strong_dyld_capture_app
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.3' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 4' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY" \
  "$TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "built-app gate rejects the retired key in the 0.1.3 trust root" \
  "expected Sparkle Ed25519 public key" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $USHOT_SPARKLE_PUBLIC_ED_KEY" \
  "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 2.9.5-ushot.3' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
expect_failure_containing \
  "built-app gate rejects the historical Sparkle fork version" \
  "framework version must equal $USHOT_SIGNED_FEED_VALIDATION_SPARKLE_VERSION" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $USHOT_SIGNED_FEED_VALIDATION_SPARKLE_VERSION" \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2063' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
expect_failure_containing \
  "built-app gate rejects the historical Sparkle fork build" \
  "framework build must equal $USHOT_SIGNED_FEED_VALIDATION_SPARKLE_BUILD" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $USHOT_SIGNED_FEED_VALIDATION_SPARKLE_BUILD" \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SURequireHostSignedAppcastValidation false' "$TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "built-app gate rejects disabled authenticated-appcast host validation" \
  "must require host validation of authenticated appcast XML" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c 'Set :SURequireHostSignedAppcastValidation true' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUHostSignedAppcastValidationVersion 0' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
expect_failure_containing \
  "built-app gate rejects a framework without signed-appcast validation marker 1" \
  "missing host signed-appcast validation marker version 1" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c 'Set :SUHostSignedAppcastValidationVersion 1' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUMaximumSignedAppcastContentLength 0' "$TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "built-app gate rejects a disabled authenticated-appcast size limit" \
  "must cap authenticated appcast XML" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c "Set :SUMaximumSignedAppcastContentLength $USHOT_MAX_AUTHENTICATED_APPCAST_BYTES" \
  "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SUFeedDownloadSizeLimitVersion 0' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
expect_failure_containing \
  "built-app gate rejects a framework without feed download-size limit marker 1" \
  "missing feed download-size limit marker version 1" \
  validate_hardened_app
/usr/libexec/PlistBuddy -c 'Set :SUFeedDownloadSizeLimitVersion 1' \
  "$TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
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
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SURequireExactUpdateVersionIdentity' \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SURequireEdDSAUpdateArchiveSignature' \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SURequireHostSignedAppcastValidation' \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SUMaximumSignedAppcastContentLength' \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SUUpdateVersionIdentityHardeningVersion' \
  "$BASELINE_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SUHostSignedAppcastValidationVersion' \
  "$BASELINE_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SUFeedDownloadSizeLimitVersion' \
  "$BASELINE_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $USHOT_SPARKLE_VERSION" \
  "$BASELINE_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $USHOT_PUBLIC_UPDATE_BASELINE_SPARKLE_BUILD" \
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
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $USHOT_SPARKLE_PUBLIC_ED_KEY" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "local installer rejects a baseline rewritten to the rotated public key" \
  "historical Sparkle Ed25519 public key" \
  validate_public_update_baseline
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $USHOT_PRE_ROTATION_SPARKLE_PUBLIC_ED_KEY" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $USHOT_APPCAST_URL" \
  "$BASELINE_TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "local installer rejects a baseline bundle that crosses feed generations" \
  "must retain the isolated legacy Sparkle feed URL" \
  validate_public_update_baseline
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $USHOT_LEGACY_APPCAST_URL" \
  "$BASELINE_TEST_APP/Contents/Info.plist"

TRANSITION_TEST_ROOT="$TEST_ROOT/historical-update-transition"
TRANSITION_TEST_APP="$TRANSITION_TEST_ROOT/Ushot.app"
mkdir -p "$TRANSITION_TEST_ROOT"
cp -R "$BASELINE_TEST_APP" "$TRANSITION_TEST_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $USHOT_UPDATE_TRANSITION_VERSION" \
  "$TRANSITION_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $USHOT_UPDATE_TRANSITION_BUILD" \
  "$TRANSITION_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $USHOT_APPCAST_URL" \
  "$TRANSITION_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SURequireExactUpdateVersionIdentity bool true' \
  "$TRANSITION_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SURequireEdDSAUpdateArchiveSignature bool true' \
  "$TRANSITION_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $USHOT_UPDATE_TRANSITION_SPARKLE_VERSION" \
  "$TRANSITION_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $USHOT_UPDATE_TRANSITION_SPARKLE_BUILD" \
  "$TRANSITION_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SUUpdateVersionIdentityHardeningVersion integer 1' \
  "$TRANSITION_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleDisplayName' "$TRANSITION_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$TRANSITION_TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$TRANSITION_TEST_APP/Contents/Info.plist"
rm "$TRANSITION_TEST_APP/Contents/Resources/AppIcon.icns"
rm "$TRANSITION_TEST_APP/Contents/Resources/Assets.car"

validate_historical_update_transition() {
  PATH="$APP_MOCK_BIN:$PATH" release_validate_app_identity \
    "$TRANSITION_TEST_APP" \
    "$USHOT_UPDATE_TRANSITION_VERSION" \
    "$USHOT_UPDATE_TRANSITION_BUILD"
}

expect_success \
  "built-app gate preserves the historical 0.1.2 identity without newer display metadata" \
  validate_historical_update_transition
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $USHOT_SPARKLE_PUBLIC_ED_KEY" \
  "$TRANSITION_TEST_APP/Contents/Info.plist"
expect_failure_containing \
  "built-app gate rejects a rotated-key rewrite of historical 0.1.2" \
  "expected Sparkle Ed25519 public key" \
  validate_historical_update_transition

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
    --proto|--user-agent|--write-out|--max-filesize)
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
      --version "0.1.4" \
      --build-number "5"
}

expect_success "exact first-feed identity accepts a versioned-feed 404" fetch_first_feed_seed
cmp "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" "$FETCH_OUTPUT" \
  || fail "first-feed bootstrap did not copy the byte-identical versioned seed"
[[ "$(<"$FETCH_KIND")" == "seed" ]] \
  || fail "first-feed bootstrap did not record seed provenance"
pass "first-feed bootstrap preserves versioned seed bytes and provenance"

OPAQUE_APPCAST_BODY="$TEST_ROOT/opaque-appcast-body"
printf '%s' '<not-yet-authenticated' > "$OPAQUE_APPCAST_BODY"
expect_success \
  "fetch preserves an HTTP 200 appcast as opaque bytes before signature verification" \
  env \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CURL_STATUS="200" \
    MOCK_CURL_BODY="$OPAQUE_APPCAST_BODY" \
    MOCK_CURL_CALLED="$FETCH_CALLED" \
    "$FETCH_SCRIPT" \
      --output "$FETCH_OUTPUT" \
      --kind-output "$FETCH_KIND" \
      --version "0.1.5" \
      --build-number "6"
cmp "$OPAQUE_APPCAST_BODY" "$FETCH_OUTPUT" \
  || fail "opaque appcast bytes changed before signature verification"
[[ "$(<"$FETCH_KIND")" == "signed" ]] \
  || fail "HTTP 200 appcast did not retain signed provenance"
pass "HTTP 200 appcast remains byte-identical and unparsed"

OVERSIZED_APPCAST_BODY="$TEST_ROOT/oversized-appcast-body"
dd if=/dev/zero \
  of="$OVERSIZED_APPCAST_BODY" \
  bs="$((USHOT_MAX_SIGNED_APPCAST_BYTES + 1))" \
  count=1 \
  2>/dev/null
expect_failure_containing \
  "fetch rejects an oversized production appcast before XML parsing" \
  "exceeds the $USHOT_MAX_SIGNED_APPCAST_BYTES-byte limit" \
  env \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CURL_STATUS="200" \
    MOCK_CURL_BODY="$OVERSIZED_APPCAST_BODY" \
    MOCK_CURL_CALLED="$FETCH_CALLED" \
    "$FETCH_SCRIPT" \
      --output "$FETCH_OUTPUT" \
      --kind-output "$FETCH_KIND" \
      --version "0.1.5" \
      --build-number "6"

rm -f "$FETCH_CALLED"
expect_failure_containing \
  "transition identity is rejected before network access" \
  "must be 0.1.4 or newer" \
  env \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CURL_STATUS="404" \
    MOCK_CURL_CALLED="$FETCH_CALLED" \
    "$FETCH_SCRIPT" \
      --output "$FETCH_OUTPUT" \
      --kind-output "$FETCH_KIND" \
      --version "0.1.3" \
      --build-number "4"
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
      --version "0.1.5" \
      --build-number "6"

ARCHIVE_PATH="$TEST_ROOT/Ushot-0.1.4-arm64.zip"
NOTES_PATH="$TEST_ROOT/0.1.4.md"
printf 'archive-payload' > "$ARCHIVE_PATH"
printf 'Release notes' > "$NOTES_PATH"
ARCHIVE_LENGTH="$(stat -f '%z' "$ARCHIVE_PATH")"
TEST_ARCHIVE_SIGNATURE="$(head -c 64 /dev/zero | base64 | tr -d '\n')"
TEST_PRIVATE_KEY_SEED="$(head -c 32 /dev/zero | base64 | tr -d '\n')"

write_appcast() {
  local output_path="$1"
  local forbidden_major_element="$2"
  cat > "$output_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- sparkle-sign-warning: generated test fixture -->
<rss version="2.0" xmlns:sparkle="$USHOT_SPARKLE_XML_NAMESPACE">
  <channel>
    <title>$USHOT_APPCAST_CHANNEL_TITLE</title>
    <link>$USHOT_APPCAST_URL</link>
    <description>$USHOT_APPCAST_CHANNEL_DESCRIPTION</description>
    <language>$USHOT_APPCAST_CHANNEL_LANGUAGE</language>
    <item>
      <sparkle:version>5</sparkle:version>
      <sparkle:shortVersionString>0.1.4</sparkle:shortVersionString>
      $forbidden_major_element
      <description sparkle:format="markdown">Release notes</description>
      <enclosure url="https://github.com/isCheneycc/ushot/releases/download/v0.1.4/Ushot-0.1.4-arm64.zip" length="$ARCHIVE_LENGTH" type="application/octet-stream" sparkle:edSignature="$TEST_ARCHIVE_SIGNATURE" />
    </item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: $TEST_ARCHIVE_SIGNATURE
length: 1
-->
EOF
}

VALID_APPCAST="$TEST_ROOT/valid-appcast.xml"
MAJOR_APPCAST="$TEST_ROOT/major-appcast.xml"
WRONG_NAMESPACE_MAJOR_APPCAST="$TEST_ROOT/wrong-namespace-major-appcast.xml"
LEGACY_LINK_APPCAST="$TEST_ROOT/legacy-link-appcast.xml"
CONFLICTING_ENCLOSURE_IDENTITY_APPCAST="$TEST_ROOT/conflicting-enclosure-identity-appcast.xml"
EXTRA_ROOT_ATTRIBUTE_APPCAST="$TEST_ROOT/extra-root-attribute-appcast.xml"
UNKNOWN_ITEM_CHILD_APPCAST="$TEST_ROOT/unknown-item-child-appcast.xml"
NONCANONICAL_LENGTH_APPCAST="$TEST_ROOT/noncanonical-length-appcast.xml"
NONCANONICAL_SIGNATURE_APPCAST="$TEST_ROOT/noncanonical-signature-appcast.xml"
write_appcast "$VALID_APPCAST" ''
write_appcast "$MAJOR_APPCAST" '<sparkle:minimumAutoupdateVersion>3</sparkle:minimumAutoupdateVersion>'
write_appcast "$WRONG_NAMESPACE_MAJOR_APPCAST" '<minimumAutoupdateVersion>3</minimumAutoupdateVersion>'
sed "s#$USHOT_APPCAST_URL#$USHOT_LEGACY_APPCAST_URL#" "$VALID_APPCAST" > "$LEGACY_LINK_APPCAST"
sed 's#<enclosure #<enclosure sparkle:version="999" sparkle:shortVersionString="9.9.9" #' \
  "$VALID_APPCAST" > "$CONFLICTING_ENCLOSURE_IDENTITY_APPCAST"
sed 's#<rss version="2.0"#<rss version="2.0" extra="value"#' \
  "$VALID_APPCAST" > "$EXTRA_ROOT_ATTRIBUTE_APPCAST"
sed 's#      <description sparkle:format="markdown">#      <unknown>value</unknown>\
      <description sparkle:format="markdown">#' \
  "$VALID_APPCAST" > "$UNKNOWN_ITEM_CHILD_APPCAST"
sed "s#length=\"$ARCHIVE_LENGTH\"#length=\"0$ARCHIVE_LENGTH\"#" \
  "$VALID_APPCAST" > "$NONCANONICAL_LENGTH_APPCAST"
sed "s#$TEST_ARCHIVE_SIGNATURE#QUJD#" \
  "$VALID_APPCAST" > "$NONCANONICAL_SIGNATURE_APPCAST"

validate_fixture() {
  "$VALIDATE_SCRIPT" \
    --appcast "$1" \
    --archive "$ARCHIVE_PATH" \
    --release-notes "$NOTES_PATH" \
    --version "0.1.4" \
    --build-number "5" \
    --tag "v0.1.4"
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
expect_failure_containing \
  "validator rejects root attributes outside the runtime allow-list" \
  "invalid-rss-root" \
  validate_fixture "$EXTRA_ROOT_ATTRIBUTE_APPCAST"
expect_failure_containing \
  "validator rejects item children outside the runtime allow-list" \
  "invalid-item-structure" \
  validate_fixture "$UNKNOWN_ITEM_CHILD_APPCAST"
expect_failure_containing \
  "validator rejects a noncanonical archive length" \
  "invalid-enclosure" \
  validate_fixture "$NONCANONICAL_LENGTH_APPCAST"
expect_failure_containing \
  "validator rejects a noncanonical archive signature" \
  "invalid-enclosure" \
  validate_fixture "$NONCANONICAL_SIGNATURE_APPCAST"

cat > "$MOCK_BIN/generate_appcast" <<'MOCK_GENERATE_APPCAST'
#!/bin/bash
set -euo pipefail

if [[ -n "${MOCK_GENERATE_CALLED_MARKER:-}" ]]; then
  : > "$MOCK_GENERATE_CALLED_MARKER"
fi
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
archive_signature="$(head -c 64 /dev/zero | base64 | tr -d '\n')"

cat > "$output_path" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- sparkle-sign-warning: generated test fixture -->
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
      <enclosure url="$download_prefix$archive_name" length="$archive_length" type="application/octet-stream" sparkle:edSignature="$archive_signature" />
    </item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: $archive_signature
length: 1
-->
EOF
MOCK_GENERATE_APPCAST
chmod +x "$MOCK_BIN/generate_appcast"

cat > "$MOCK_BIN/sign_update" <<'MOCK_SIGN_UPDATE'
#!/bin/bash
exit 0
MOCK_SIGN_UPDATE
chmod +x "$MOCK_BIN/sign_update"

EARLY_STDIN_READ_MARKER="$TEST_ROOT/early-stdin-read"
cat > "$MOCK_BIN/dirname" <<'MOCK_DIRNAME'
#!/bin/bash
set -euo pipefail

captured=""
IFS= read -r captured || true
if [[ -n "$captured" && -n "${MOCK_EARLY_STDIN_READ:-}" ]]; then
  : > "$MOCK_EARLY_STDIN_READ"
fi
exec /usr/bin/dirname "$@"
MOCK_DIRNAME
chmod +x "$MOCK_BIN/dirname"

MOCK_GENERATE_ARGUMENTS="$TEST_ROOT/generate-arguments.txt"
FIRST_FEED_ARCHIVE="$ARCHIVE_PATH"
FIRST_FEED_NOTES="$NOTES_PATH"

run_seed_generation() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_EARLY_STDIN_READ="$EARLY_STDIN_READ_MARKER" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin"
}

MALFORMED_KEY_SENTINEL="malformed-key-sentinel"
set +e
MALFORMED_KEY_OUTPUT="$(
  printf '%s' "$MALFORMED_KEY_SENTINEL" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_EARLY_STDIN_READ="$EARLY_STDIN_READ_MARKER" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        2>&1
)"
MALFORMED_KEY_STATUS=$?
set -e
[[ "$MALFORMED_KEY_STATUS" -ne 0 ]] \
  || fail "generator unexpectedly accepted a malformed private key"
case "$MALFORMED_KEY_OUTPUT" in
  *"$MALFORMED_KEY_SENTINEL"*)
    fail "generator exposed malformed private-key input in diagnostics"
    ;;
esac
case "$MALFORMED_KEY_OUTPUT" in
  *"canonical base64"*) ;;
  *) fail "generator did not report canonical private-key validation failure" ;;
esac
pass "generator rejects malformed private keys without logging their bytes"

expect_success "generator signs the exact first versioned-feed seed" run_seed_generation
[[ ! -e "$EARLY_STDIN_READ_MARKER" ]] \
  || fail "an external preflight command inherited the signing-key stream"
pass "generator closes the signing-key stream before external preflight"
if grep -Fxq -- '--major-version' "$MOCK_GENERATE_ARGUMENTS"; then
  fail "generate_appcast received forbidden --major-version"
fi
pass "generator does not emit a major-upgrade marker"
[[ -s "$SITE_DIRECTORY/$USHOT_APPCAST_RELATIVE_PATH" ]] \
  || fail "generator did not emit the canonical versioned Pages path"
[[ ! -e "$SITE_DIRECTORY/updates/appcast.xml" ]] \
  || fail "generator recreated the permanently absent legacy feed path"
pass "Pages payload contains only the versioned feed path"
"$VALIDATE_SCRIPT" \
  --appcast "$SITE_DIRECTORY/$USHOT_APPCAST_RELATIVE_PATH" \
  --archive "$FIRST_FEED_ARCHIVE" \
  --release-notes "$FIRST_FEED_NOTES" \
  --version "0.1.4" \
  --build-number "5" \
  --tag "v0.1.4" \
  >/dev/null \
  || fail "generated appcast did not pass the independent validator"
pass "generated versioned appcast independently validates"

SIGNING_BOUNDARY_BIN="$TEST_ROOT/signing-boundary-bin"
SIGNING_BOUNDARY_RUNTIME_MARKER="$TEST_ROOT/signing-boundary-runtime-validator"
SIGNING_BOUNDARY_GENERATOR_MARKER="$TEST_ROOT/signing-boundary-generate-appcast"
mkdir -p "$SIGNING_BOUNDARY_BIN"
cat > "$SIGNING_BOUNDARY_BIN/swift" <<'MOCK_SIGNING_BOUNDARY_SWIFT'
#!/bin/bash
set -euo pipefail
: > "${MOCK_SIGNING_BOUNDARY_RUNTIME_MARKER:?}"
exit 97
MOCK_SIGNING_BOUNDARY_SWIFT
chmod +x "$SIGNING_BOUNDARY_BIN/swift"

PUBLIC_KEY_DERIVER="$AUTHENTICATED_VALIDATOR_ROOT/SparklePublicKeyDeriver"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -O \
  "$DERIVE_KEY_SCRIPT" \
  -o "$PUBLIC_KEY_DERIVER"
PUBLIC_KEY_DERIVER_SHA256="$(release_sha256 "$PUBLIC_KEY_DERIVER")"
[[ "$PUBLIC_KEY_DERIVER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "could not bind the standalone public-key deriver"

run_seed_generation_at_signing_boundary() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$SIGNING_BOUNDARY_BIN:$MOCK_BIN:$PATH" \
      MOCK_EARLY_STDIN_READ="$EARLY_STDIN_READ_MARKER" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      MOCK_SIGNING_BOUNDARY_RUNTIME_MARKER="$SIGNING_BOUNDARY_RUNTIME_MARKER" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --public-key-deriver "$PUBLIC_KEY_DERIVER" \
        --public-key-deriver-sha256 "$PUBLIC_KEY_DERIVER_SHA256" \
        --authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR" \
        --authenticated-appcast-validator-sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
        --signing-boundary-output-only
}

expect_success \
  "signing-boundary mode validates and stages authenticated bytes with the reviewed executable" \
  run_seed_generation_at_signing_boundary
[[ ! -e "$SIGNING_BOUNDARY_RUNTIME_MARKER" ]] \
  || fail "signing-boundary mode dynamically compiled repository runtime code"
pass "signing-boundary validation uses the prebuilt checksum-bound executable"

run_signing_boundary_without_reviewed_deriver() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR" \
        --authenticated-appcast-validator-sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
        --signing-boundary-output-only
}

expect_failure_containing \
  "signing-boundary mode requires the reviewed public-key deriver" \
  "requires a reviewed public-key deriver" \
  run_signing_boundary_without_reviewed_deriver

run_signing_boundary_with_absolute_swift_as_deriver() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --public-key-deriver "/usr/bin/swift" \
        --public-key-deriver-sha256 "$(release_sha256 /usr/bin/swift)" \
        --authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR" \
        --authenticated-appcast-validator-sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
        --signing-boundary-output-only
}

expect_failure_containing \
  "signing-boundary mode cannot select absolute Swift as the key deriver" \
  "not a Swift runtime or compiler" \
  run_signing_boundary_with_absolute_swift_as_deriver

run_signing_boundary_with_relative_deriver() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --public-key-deriver "SparklePublicKeyDeriver" \
        --public-key-deriver-sha256 "$PUBLIC_KEY_DERIVER_SHA256" \
        --authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR" \
        --authenticated-appcast-validator-sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
        --signing-boundary-output-only
}

expect_failure_containing \
  "signing-boundary mode requires an absolute public-key deriver path" \
  "Public-key deriver path must be absolute" \
  run_signing_boundary_with_relative_deriver

run_signing_boundary_with_wrong_deriver_digest() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --public-key-deriver "$PUBLIC_KEY_DERIVER" \
        --public-key-deriver-sha256 "0000000000000000000000000000000000000000000000000000000000000000" \
        --authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR" \
        --authenticated-appcast-validator-sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
        --signing-boundary-output-only
}

expect_failure_containing \
  "signing-boundary mode rejects a changed public-key deriver" \
  "Public-key deriver checksum does not match the reviewed executable" \
  run_signing_boundary_with_wrong_deriver_digest

run_signing_boundary_without_reviewed_validator() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --signing-boundary-output-only
}

expect_failure_containing \
  "signing-boundary mode requires the reviewed authenticated-appcast validator" \
  "requires a reviewed authenticated-appcast validator" \
  run_signing_boundary_without_reviewed_validator

run_signing_boundary_with_wrong_validator_digest() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.4" \
        --build-number "5" \
        --tag "v0.1.4" \
        --archive "$FIRST_FEED_ARCHIVE" \
        --release-notes "$FIRST_FEED_NOTES" \
        --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
        --existing-appcast-kind "seed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --public-key-deriver "$PUBLIC_KEY_DERIVER" \
        --public-key-deriver-sha256 "$PUBLIC_KEY_DERIVER_SHA256" \
        --authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR" \
        --authenticated-appcast-validator-sha256 "0000000000000000000000000000000000000000000000000000000000000000" \
        --signing-boundary-output-only
}

expect_failure_containing \
  "signing-boundary mode rejects a changed authenticated-appcast validator" \
  "checksum does not match the reviewed executable" \
  run_signing_boundary_with_wrong_validator_digest

run_signing_boundary_with_keychain() {
  "$GENERATE_SCRIPT" \
    --version "0.1.4" \
    --build-number "5" \
    --tag "v0.1.4" \
    --archive "$FIRST_FEED_ARCHIVE" \
    --release-notes "$FIRST_FEED_NOTES" \
    --existing-appcast "$PROJECT_ROOT/$USHOT_APPCAST_RELATIVE_PATH" \
    --existing-appcast-kind "seed" \
    --site-directory "$SITE_DIRECTORY" \
    --sparkle-bin "$MOCK_BIN" \
    --key-source "keychain" \
    --signing-boundary-output-only
}

expect_failure_containing \
  "signing-boundary mode requires an explicitly supplied in-memory key" \
  "requires --key-source stdin" \
  run_signing_boundary_with_keychain

FUTURE_ARCHIVE="$TEST_ROOT/Ushot-0.1.5-arm64.zip"
FUTURE_NOTES="$TEST_ROOT/0.1.5.md"
printf 'future-archive' > "$FUTURE_ARCHIVE"
printf 'Future notes' > "$FUTURE_NOTES"

run_future_with_policy_invalid_signed_history_at_boundary() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      MOCK_GENERATE_CALLED_MARKER="$SIGNING_BOUNDARY_GENERATOR_MARKER" \
      "$GENERATE_SCRIPT" \
        --version "0.1.5" \
        --build-number "6" \
        --tag "v0.1.5" \
        --archive "$FUTURE_ARCHIVE" \
        --release-notes "$FUTURE_NOTES" \
        --existing-appcast "$EXTRA_ROOT_ATTRIBUTE_APPCAST" \
        --existing-appcast-kind "signed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin" \
        --public-key-deriver "$PUBLIC_KEY_DERIVER" \
        --public-key-deriver-sha256 "$PUBLIC_KEY_DERIVER_SHA256" \
        --authenticated-appcast-validator "$AUTHENTICATED_APPCAST_VALIDATOR" \
        --authenticated-appcast-validator-sha256 "$AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
        --signing-boundary-output-only
}

[[ ! -e "$SIGNING_BOUNDARY_GENERATOR_MARKER" ]] \
  || fail "signing-boundary generator marker was not fresh"
expect_failure_containing \
  "signing boundary rejects policy-invalid signed history before generator normalization" \
  "invalid-rss-root" \
  run_future_with_policy_invalid_signed_history_at_boundary
[[ ! -e "$SIGNING_BOUNDARY_GENERATOR_MARKER" ]] \
  || fail "signing boundary invoked generate_appcast before rejecting invalid authenticated history"
pass "invalid authenticated history cannot be normalized by generate_appcast"

assert_signing_job_has_no_swift_toolchain_execution() {
  local signing_job

  signing_job="$(awk '
    /^  sign-update-feed:$/ { in_job = 1 }
    in_job && /^  [A-Za-z0-9_-]+:$/ && $0 != "  sign-update-feed:" { exit }
    in_job { print }
  ' "$RELEASE_WORKFLOW")"
  [[ -n "$signing_job" ]] || return 1
  if grep -Eq '(^|[[:space:];|&])(/usr/bin/)?(swift|swiftc|xcrun)([[:space:];|&]|$)' <<< "$signing_job"; then
    return 1
  fi
  ! grep -Fq 'derive-sparkle-public-key.swift' <<< "$signing_job"
}

expect_success \
  "secret-bearing sign-update-feed job cannot execute the Swift toolchain or derive source" \
  assert_signing_job_has_no_swift_toolchain_execution

assert_runtime_validation_reuses_reviewed_helper_artifact() {
  local validation_job

  validation_job="$(awk '
    /^  validate-signed-appcast:$/ { in_job = 1 }
    in_job && /^  [A-Za-z0-9_-]+:$/ && $0 != "  validate-signed-appcast:" { exit }
    in_job { print }
  ' "$RELEASE_WORKFLOW")"
  [[ -n "$validation_job" ]] || return 1
  grep -Fq -- '- build-authenticated-appcast-validator' <<< "$validation_job"
  grep -Fq 'needs.build-authenticated-appcast-validator.outputs.validator_artifact_id' \
    <<< "$validation_job"
  grep -Fq 'USHOT_AUTHENTICATED_APPCAST_VALIDATOR_SHA256' <<< "$validation_job"
  grep -Fq 'digest-mismatch: error' <<< "$validation_job"
  if grep -Eq '(^|[[:space:];|&])(/usr/bin/)?(swift|swiftc|xcrun)([[:space:];|&]|$)' \
      <<< "$validation_job"; then
    return 1
  fi
}

expect_success \
  "credential-free runtime validation reuses the immutable reviewed helper without compilation" \
  assert_runtime_validation_reuses_reviewed_helper_artifact

assert_reviewed_release_common_hashes_match() {
  local actual_sha256

  actual_sha256="$(release_sha256 "$SCRIPT_DIR/release-common.sh")"
  [[ "$actual_sha256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$(grep -Fc "EXPECTED_RELEASE_COMMON_SCRIPT_SHA256='$actual_sha256'" "$RELEASE_WORKFLOW")" == "1" ]]
  [[ "$(grep -Fc "readonly EXPECTED_RELEASE_COMMON_SHA256=\"$actual_sha256\"" \
      "$SCRIPT_DIR/verify-update-transition.sh")" == "1" ]]
  [[ "$(grep -Fc "EXPECTED_RELEASE_COMMON_SHA256 = \"$actual_sha256\"" \
      "$SCRIPT_DIR/serve-update-transition-loopback.sh")" == "1" ]]
}

expect_success \
  "reviewed release-common hashes match every protected signing and transition boundary" \
  assert_reviewed_release_common_hashes_match

workflow_job_runner() {
  local workflow="$1"
  local job="$2"

  awk -v job="  $job:" '
    $0 == job { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:$/ { exit }
    in_job && $1 == "runs-on:" { print $2; exit }
  ' "$workflow"
}

workflow_job_body() {
  local workflow="$1"
  local job="$2"

  awk -v job="  $job:" '
    $0 == job { in_job = 1 }
    in_job && $0 != job && /^  [A-Za-z0-9_-]+:$/ { exit }
    in_job { print }
  ' "$workflow"
}

workflow_job_selects_xcode_26_3() {
  local workflow="$1"
  local job="$2"

  workflow_job_body "$workflow" "$job" | grep -Fq \
    'DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer'
}

assert_sdk_runner_boundaries() {
  local compatibility_job

  [[ "$(workflow_job_runner "$CI_WORKFLOW" release-metadata)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$CI_WORKFLOW" unit-tests)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$CI_WORKFLOW" public-build-gate)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$CI_WORKFLOW" macos-14-launch-smoke)" == "macos-14" ]]
  [[ "$(workflow_job_runner "$RELEASE_WORKFLOW" build-artifacts)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$RELEASE_WORKFLOW" preflight)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$RELEASE_WORKFLOW" build-authenticated-appcast-validator)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$RELEASE_WORKFLOW" sign-update-feed)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$RELEASE_WORKFLOW" validate-signed-appcast)" == "macos-15" ]]
  [[ "$(workflow_job_runner "$RELEASE_WORKFLOW" publish-release)" == "macos-15" ]]
  workflow_job_selects_xcode_26_3 "$CI_WORKFLOW" unit-tests
  workflow_job_selects_xcode_26_3 "$CI_WORKFLOW" public-build-gate
  workflow_job_selects_xcode_26_3 "$RELEASE_WORKFLOW" build-artifacts

  compatibility_job="$(workflow_job_body "$CI_WORKFLOW" macos-14-launch-smoke)"
  [[ -n "$compatibility_job" ]]
  grep -Fq 'needs: public-build-gate' <<< "$compatibility_job"
  grep -Fq 'compatibility_artifact_id' <<< "$compatibility_job"
  grep -Fq 'compatibility_artifact_digest' <<< "$compatibility_job"
  grep -Fq '.workflow_run.id == $run_id' <<< "$compatibility_job"
  grep -Fq 'digest-mismatch: error' <<< "$compatibility_job"
  grep -Fq 'otool -L "$BINARY"' <<< "$compatibility_job"
  grep -Fq 'nm -m "$BINARY"' <<< "$compatibility_job"
  grep -Fq 'dyld_info -imports "$BINARY"' <<< "$compatibility_job"
  grep -Fq 'dyld_info -fixups "$BINARY"' <<< "$compatibility_job"
  grep -Fq '"$BINARY" >"$ROOT/launch.log" 2>&1 &' <<< "$compatibility_job"
  grep -Fq 'kill -0 "$APP_PID"' <<< "$compatibility_job"
}

expect_success \
  "SDK 26 app builds execute on old-system runners and stay separated from release control and signing jobs" \
  assert_sdk_runner_boundaries

run_future_with_seed() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.5" \
        --build-number "6" \
        --tag "v0.1.5" \
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
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.5" \
        --build-number "6" \
        --tag "v0.1.5" \
        --archive "$FUTURE_ARCHIVE" \
        --release-notes "$FUTURE_NOTES" \
        --existing-appcast "$CONFLICTING_ENCLOSURE_IDENTITY_APPCAST" \
        --existing-appcast-kind "signed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin"
}

expect_failure_containing \
  "generator rejects retained enclosure ambiguity before normalization" \
  "invalid-enclosure" \
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
<!-- sparkle-signatures:
edSignature: $TEST_ARCHIVE_SIGNATURE
length: 1
-->
EOF

run_future_with_empty_signed_history() {
  printf '%s' "$TEST_PRIVATE_KEY_SEED" | \
    env MOCK_GENERATE_ARGUMENTS="$MOCK_GENERATE_ARGUMENTS" \
      "$GENERATE_SCRIPT" \
        --version "0.1.5" \
        --build-number "6" \
        --tag "v0.1.5" \
        --archive "$FUTURE_ARCHIVE" \
        --release-notes "$FUTURE_NOTES" \
        --existing-appcast "$SIGNED_EMPTY_APPCAST" \
        --existing-appcast-kind "signed" \
        --site-directory "$SITE_DIRECTORY" \
        --sparkle-bin "$MOCK_BIN" \
        --key-source "stdin"
}

expect_failure_containing \
  "generator rejects a signed feed with reset history before normalization" \
  "missing-update-items" \
  run_future_with_empty_signed_history

printf '1..%d\n' "$PASS_COUNT"
