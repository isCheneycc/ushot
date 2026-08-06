#!/bin/bash
set -euo pipefail
set +x
ulimit -c 0
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# This verifier sources release-common.sh before any evidence boundary exists. Refuse
# an unexpected owner or writable source up front instead of letting a locally
# replaced helper execute and then attest to its own output.
launch_uid="$(/usr/bin/id -u)"
for launch_source in "$SCRIPT_DIR/verify-update-transition.sh" "$SCRIPT_DIR/release-common.sh"; do
  [[ -f "$launch_source" && ! -L "$launch_source" ]] || {
    printf 'release: error: Transition verifier source must be a regular, non-symbolic-link file: %s\n' "$launch_source" >&2
    exit 1
  }
  launch_source_uid="$(/usr/bin/stat -f '%u' "$launch_source")"
  launch_source_mode="$(/usr/bin/stat -f '%Lp' "$launch_source")"
  [[ "$launch_source_uid" == "$launch_uid" ]] || {
    printf 'release: error: Transition verifier source has an unexpected owner: %s\n' "$launch_source" >&2
    exit 1
  }
  launch_source_mode_decimal=$((8#$launch_source_mode))
  (( (launch_source_mode_decimal & 0022) == 0 )) || {
    printf 'release: error: Transition verifier source must not be group- or world-writable: %s\n' "$launch_source" >&2
    exit 1
  }
done
unset launch_uid launch_source launch_source_uid launch_source_mode launch_source_mode_decimal

# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

readonly INSTALLED_APP="/Applications/Ushot.app"
readonly REQUEST_EVIDENCE_SCHEMA="ushot-update-transition-loopback-corroborating-v2"
readonly OPERATOR_ATTESTATION_SCHEMA="ushot-update-transition-operator-attestation-v1"
# Independently reviewed immutable loopback implementation. Admission fails
# closed if its complete bytes or executable mode differ from this sentinel.
readonly LOOPBACK_SERVER_SHA256="39066a61329e5b10f5413285ecb74c66f4df3925e647716ad079fcc35f2d9ab0"
readonly LOOPBACK_SERVER_SIZE="100717"
readonly EVIDENCE_SCHEMA="3"
readonly ARCHIVE_NAME="Ushot-0.1.4-arm64.zip"
readonly EXPECTED_FIXTURE_SCRIPT_SHA256="7a486638f663bb84273b94fdfd29881a0eadcf8efd0e9c4c2069629ea4b6a1ea"
readonly EXPECTED_FROZEN_BUNDLE_MANIFEST_SHA256="f95eaf74a550f670dbc5d9dd5eecb9b8b46cfa71b6f446cd8ca19ba28c461dce"
readonly EXPECTED_REVIEWED_SOURCE_MANIFEST_SHA256="bfba9260ecb2588962dad096b38804240f21179b62a3d456a13ce2a17160c075"
readonly EXPECTED_RELEASE_COMMON_SHA256="608280e518bd010f842da932b10b050e002e9553aa21473c1c9338e8e1035684"
readonly EXPECTED_VALIDATE_APPCAST_SHA256="5e5314c0059b95b36e4033ccc01ad1e55ebf3c4620d9d4aa7e94e75e524f6b9f"
readonly EXPECTED_GENERATE_APPCAST_SHA256="669a5ed0f90ce06fb1de3e36aba35c5da8b98f66928a185fd4029174071be700"
readonly EXPECTED_GENERATE_KEYS_SHA256="2d18ed3a9c744e58150513d9b2e3c2eb76fd0b9621e3e4678d46dd972547e8fe"
readonly EXPECTED_SIGN_UPDATE_SHA256="bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad"
readonly EXPECTED_AUTHENTICATED_APPCAST_VALIDATOR_SHA256="ded0593a34edc3d592871bbe8a0902e4e3c6cfe03fe043cb8f604c2e4c3825a4"
readonly EXPECTED_PUBLIC_KEY_DERIVER_SHA256="ae1ab09dfcd799db9aeaee86eaa223f6cd6e10f837c1879453749ce46fd11738"
readonly EXPECTED_EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256="6a7178ebcbb10b248d8899baafed1540c021b91b71afaedf19c3243c73d23ed6"
readonly EXPECTED_RELEASE_NOTES_SHA256="d7f0398e99bad381502b500cc75969fc869678566199089e54ec8d0bd7ce19b5"
readonly EXPECTED_CANDIDATE_DMG_SHA256="96cd69ccb204d340be5ac404a0492cf7fe998e4cf7bc6e865fc2a7708dd68628"
readonly EXPECTED_CANDIDATE_ZIP_SHA256="0653d37479d4b8964a3147d92d9baf55f9f18883f1c6e0fa813bbdce50c01998"
readonly EXPECTED_CANDIDATE_DSYM_SHA256="1c26bf01ab9fb5e0ba1862d1bc4cfcd9d69cd3b0c134aa13c221c2491c6406d1"
readonly EXPECTED_CANDIDATE_MANIFEST_SHA256="40b91ee67253bd434ed61552c993686e2925ba07c5ebb742c8e6395df1198029"
readonly EXPECTED_CANDIDATE_CHECKSUMS_SHA256="5e5e438133939749c9b4fc6aec355a016005c438fa5a7dc11c0fcb69460be2f0"
readonly MAX_FIXTURE_FEED_BYTES="2097152"
readonly MAX_FIXTURE_ARCHIVE_BYTES="134217728"
readonly BASELINE_TAG="v0.1.3"
readonly BASELINE_VERSION="0.1.3"
readonly BASELINE_BUILD="4"
readonly BASELINE_DMG_NAME="Ushot-0.1.3-arm64.dmg"
readonly BASELINE_ZIP_NAME="Ushot-0.1.3-arm64.zip"
readonly BASELINE_DSYM_NAME="Ushot-0.1.3-arm64.dSYM.zip"
readonly BASELINE_MANIFEST_NAME="Ushot-0.1.3-arm64.release-manifest.json"
readonly BASELINE_CHECKSUMS_NAME="SHA256SUMS.txt"
readonly BASELINE_DMG_SHA256="223041e8b60321572a5952183331de4e13101ad119cd39b36244ddb7aef58349"
readonly BASELINE_ZIP_SHA256="91b4fbe2c40826aec909cb38f3fea5e2056e40b5dfc2fbe54b3efeb1d687efc8"
readonly BASELINE_DSYM_SHA256="d540d593a7b745b3068792cd0dd296c8aea74e7792031ffdb29b4cfc18c9854f"
readonly BASELINE_MANIFEST_SHA256="78410b923978e825083c164db9c308f37b3c7062d81899d9e173911a951529c0"
readonly BASELINE_CHECKSUMS_SHA256="19ba42accdad1c288966bc947f9905a9bc70b79e172a3a09b11f47cba30a99cf"
readonly BASELINE_DMG_SIZE="4262821"
readonly BASELINE_ZIP_SIZE="3873540"
readonly BASELINE_DSYM_SIZE="4444320"
readonly BASELINE_MANIFEST_SIZE="890"
readonly BASELINE_CHECKSUMS_SIZE="375"

REPORT_DIRECTORY=""
FIXTURES_ROOT=""
BASELINE_ASSETS_DIRECTORY=""
CASE_LABEL=""
REQUEST_EVIDENCE=""
APP_LOG_EVIDENCE=""
SPARKLE_LOG_EVIDENCE=""
OPERATOR_ATTESTATION=""
REQUEST_GENERATION=""
APP_GENERATION=""
FEED_TRANSFER_MODE="normal"
EXPECTED_BASELINE_DIGEST=""
EXPECTED_RUNTIME_DIGEST=""
EXPECTED_CONTROLLED_DIGEST=""
ACTIVE_PHASE_DIRECTORY=""
ACTIVE_STAGE=""
RESULT_RECORDED=false
CURRENT_UID=""

FIXTURE_MANIFEST=""
FIXTURE_CHECKSUMS=""
FEED_FIXTURE=""
ARCHIVE_FIXTURE=""
FIXTURE_FEED_SHA256=""
FIXTURE_ARCHIVE_SHA256=""
FIXTURE_FEED_SIZE=""
FIXTURE_ARCHIVE_SIZE=""
FIXTURE_XML_POLICY=""
FIXTURE_XML_REJECTION_CATEGORY=""
FIXTURE_ARCHIVE_EDDSA=""
FIXTURE_BUNDLE_VERSION=""
FIXTURE_BUNDLE_BUILD=""
FIXTURE_EXPECTED_RESULT=""
FIXTURE_MANIFEST_SHA256=""
FIXTURE_CHECKSUMS_SHA256=""

usage() {
  printf '%s\n' \
    "usage:" \
    "  $0 prepare --report-directory /absolute/private/report --baseline-assets-directory /absolute/private/v0.1.3-assets --fixtures-root /absolute/private/fixtures --case normal" \
    "  $0 baseline --report-directory /absolute/private/report --baseline-assets-directory /absolute/private/v0.1.3-assets --fixtures-root /absolute/private/fixtures --case normal" \
    "  $0 negative-verify --report-directory /absolute/private/report --fixtures-root /absolute/private/fixtures --case CASE --request-evidence /absolute/requests.tsv --request-generation N --app-generation N --operator-attestation /absolute/attestation.tsv --baseline-digest SHA256 [options]" \
    "  $0 finalize-negative --report-directory /absolute/private/report --case CASE --request-evidence /absolute/requests.tsv --request-generation N --app-generation N --baseline-digest SHA256 --runtime-digest SHA256" \
    "  $0 success-verify --report-directory /absolute/private/report --fixtures-root /absolute/private/fixtures --case normal --request-evidence /absolute/requests.tsv --request-generation N --app-generation N --operator-attestation /absolute/attestation.tsv --baseline-digest SHA256 [options]" \
    "  $0 finalize-success --report-directory /absolute/private/report --case normal --request-evidence /absolute/requests.tsv --request-generation N --app-generation N --baseline-digest SHA256 --controlled-digest SHA256" \
    "  $0 self-test" \
    "" \
    "Options:" \
    "  --feed-transfer-mode normal|chunked   Exact loopback feed transport mode (default: normal)." \
    "  --app-log-evidence FILE               Previously exported Ushot updates NDJSON; otherwise log show is queried read-only." \
    "  --sparkle-log-evidence FILE           Previously exported filtered Sparkle NDJSON for archive-stage negatives." \
    "  --baseline-digest SHA256              Externally retained baseline local-integrity digest." \
    "  --runtime-digest SHA256               Externally retained negative runtime-phase integrity digest." \
    "  --controlled-digest SHA256            Externally retained controlled success-phase integrity digest." \
    "  --operator-attestation FILE           Current-user-owned mode-0600 structured observation evidence." \
    "" \
    "The fixture paths are derived from the verified SHA256SUMS.txt and exact" \
    "fixture-manifest.json case entry. Arbitrary feed/archive paths are not accepted." \
    "A negative runtime check stops at RUNTIME_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP; only" \
    "finalize-negative may emit PASS after the same append-only session records a" \
    "successful service end and port-443 cleanup. Success verification first stops at" \
    "CONTROLLED_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP_AND_PROVENANCE_DECISION;" \
    "finalize-success verifies cleanup and then stops at" \
    "CONTROLLED_VERIFICATION_COMPLETE_PENDING_PROVENANCE_DECISION because same-UID evidence" \
    "cannot independently prove that Sparkle, rather than an operator, replaced the app." \
    "Missing runtime evidence produces INCOMPLETE, never PASS. The script does not" \
    "click Ushot, replace the app, terminate a process, or change network/trust state."
}

sanitize_reason() {
  printf '%s' "$1" | /usr/bin/tr '\t\r\n' '   ' | /usr/bin/cut -c 1-240
}

record_phase_failure_on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$RESULT_RECORDED" != "true" \
      && -n "$ACTIVE_PHASE_DIRECTORY" \
      && -d "$ACTIVE_PHASE_DIRECTORY" \
      && ! -L "$ACTIVE_PHASE_DIRECTORY" ]]; then
    printf 'stage\t%s\nresult\tFAIL\nexit_status\t%s\n' \
      "${ACTIVE_STAGE:-unknown}" "$status" \
      > "$ACTIVE_PHASE_DIRECTORY/result.tsv"
    chmod 600 "$ACTIVE_PHASE_DIRECTORY/result.tsv"
  fi
  exit "$status"
}
trap record_phase_failure_on_exit EXIT

write_result_file() {
  local result="$1"
  local status="$2"
  local reason="${3:-}"

  printf 'stage\t%s\nresult\t%s\nexit_status\t%s\n' \
    "$ACTIVE_STAGE" "$result" "$status" \
    > "$ACTIVE_PHASE_DIRECTORY/result.tsv"
  if [[ -n "$reason" ]]; then
    printf 'reason\t%s\n' "$(sanitize_reason "$reason")" \
      >> "$ACTIVE_PHASE_DIRECTORY/result.tsv"
  fi
  chmod 600 "$ACTIVE_PHASE_DIRECTORY/result.tsv"
}

record_result() {
  write_result_file "$@"
  RESULT_RECORDED=true
}

record_incomplete() {
  local reason="$1"
  local evidence_path="$ACTIVE_PHASE_DIRECTORY/evidence.tsv"

  if [[ -f "$evidence_path" && ! -L "$evidence_path" ]]; then
    printf 'completion\tINCOMPLETE\nincomplete_reason\t%s\n' \
      "$(sanitize_reason "$reason")" >> "$evidence_path"
    chmod 600 "$evidence_path"
  fi
  record_result INCOMPLETE 2 "$reason"
  printf 'stage=%s\nresult=INCOMPLETE\nreason=%s\nreport_directory=%s\n' \
    "$ACTIVE_STAGE" "$(sanitize_reason "$reason")" "$REPORT_DIRECTORY"
  exit 2
}

require_non_root_user() {
  CURRENT_UID="$(id -u)"
  [[ "$CURRENT_UID" =~ ^[1-9][0-9]*$ ]] \
    || release_die "Transition verification must run as the logged-in non-root app user."
}

record_operator_account_context() {
  local evidence_path="$1"
  local current_user console_uid console_user membership_output membership_status
  local admin_member account_classification clean_gate

  current_user="$(/usr/bin/id -un "$CURRENT_UID")" \
    || release_die "Could not resolve the verifier user's account name."
  [[ -n "$current_user" && "$(/usr/bin/id -u "$current_user")" == "$CURRENT_UID" ]] \
    || release_die "Verifier UID and account-name resolution are inconsistent."
  console_uid="$(/usr/bin/stat -f '%u' /dev/console)" \
    || release_die "Could not resolve the current console UID."
  console_user="$(/usr/bin/stat -f '%Su' /dev/console)" \
    || release_die "Could not resolve the current console user."
  [[ "$current_user" =~ ^[A-Za-z0-9._-]+$ \
      && "$console_uid" =~ ^[0-9]+$ \
      && "$console_user" =~ ^[A-Za-z0-9._-]+$ ]] \
    || release_die "The current console account identity is malformed."
  [[ "$console_uid" == "$CURRENT_UID" && "$console_user" == "$current_user" ]] \
    || release_die "Transition verification must run as the active console app user."

  set +e
  membership_output="$(LC_ALL=C /usr/bin/dsmemberutil checkmembership -U "$current_user" -G admin 2>&1)"
  membership_status=$?
  set -e
  [[ "$membership_status" == "0" ]] \
    || release_die "Could not determine current-user membership in the admin group."
  case "$membership_output" in
    "user is a member of the group")
      admin_member="true"
      account_classification="CURRENT_ADMIN_ACCOUNT_NOT_CLEAN_ACCOUNT"
      clean_gate="NOT_SATISFIED_ADMIN_ACCOUNT"
      ;;
    "user is not a member of the group")
      admin_member="false"
      account_classification="CURRENT_STANDARD_ACCOUNT_NOT_PROVEN_CLEAN_ACCOUNT"
      clean_gate="NOT_SATISFIED_CLEANLINESS_NOT_PROVEN"
      ;;
    *) release_die "Admin-group membership returned an unrecognized result." ;;
  esac

  printf '%b\n' \
    "current_uid\t$CURRENT_UID" \
    "current_user\t$current_user" \
    "console_uid\t$console_uid" \
    "console_user\t$console_user" \
    "current_user_admin_member\t$admin_member" \
    "current_account_classification\t$account_classification" \
    "clean_standard_account_final_gate\t$clean_gate" \
    'account_membership_observation\tDSMEMBERUTIL_EXACT_RESULT' \
    >> "$evidence_path"
}

require_canonical_directory() {
  local path="$1"
  local description="$2"

  [[ "$path" == /* && -d "$path" && ! -L "$path" ]] \
    || release_die "$description must be an absolute existing real directory."
  [[ "$(cd "$path" && pwd -P)" == "$path" ]] \
    || release_die "$description must already be canonical and may not traverse symbolic links."
  printf '%s\n' "$path"
}

require_canonical_file() {
  local path="$1"
  local description="$2"
  local parent canonical_parent canonical_path

  [[ "$path" == /* ]] || release_die "$description path must be absolute."
  parent="$(dirname "$path")"
  [[ -d "$parent" && ! -L "$parent" ]] \
    || release_die "$description parent must be an existing real directory."
  canonical_parent="$(cd "$parent" && pwd -P)"
  canonical_path="$canonical_parent/$(basename "$path")"
  [[ "$path" == "$canonical_path" ]] \
    || release_die "$description path must be canonical and may not traverse symbolic links."
  [[ -f "$canonical_path" && ! -L "$canonical_path" && -s "$canonical_path" ]] \
    || release_die "$description must be a nonempty regular, non-symbolic-link file."
  printf '%s\n' "$canonical_path"
}

require_private_input_file() {
  local path="$1"
  local description="$2"
  local canonical

  canonical="$(require_canonical_file "$path" "$description")"
  [[ "$(stat -f '%u' "$canonical")" == "$CURRENT_UID" ]] \
    || release_die "$description must be owned by the current user."
  [[ "$(stat -f '%Lp' "$canonical")" == "600" ]] \
    || release_die "$description permissions must be exactly 0600."
  printf '%s\n' "$canonical"
}

require_private_evidence_file() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" \
      && "$(stat -f '%u' "$path")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$path")" == "600" ]] \
    || release_die "Required evidence file must be current-user-owned mode 0600: $path"
}

require_private_phase_file() {
  local path="$1" mode
  [[ -f "$path" && ! -L "$path" && "$(stat -f '%u' "$path")" == "$CURRENT_UID" ]] \
    || release_die "Required phase file must be regular, non-symbolic and current-user-owned: $path"
  mode="$(stat -f '%Lp' "$path")"
  (( (8#$mode & 0077) == 0 )) \
    || release_die "Required phase file grants group/world permissions: $path"
}

create_report_directory() {
  local report_directory="$1"
  local parent canonical_parent expected_path

  [[ "$report_directory" == /* ]] \
    || release_die "Report directory path must be absolute."
  parent="$(dirname "$report_directory")"
  [[ -d "$parent" && ! -L "$parent" ]] \
    || release_die "Report directory parent must be an existing real directory."
  canonical_parent="$(cd "$parent" && pwd -P)"
  expected_path="$canonical_parent/$(basename "$report_directory")"
  [[ "$report_directory" == "$expected_path" ]] \
    || release_die "Report directory path must be canonical and may not traverse symbolic links."
  [[ ! -e "$report_directory" && ! -L "$report_directory" ]] \
    || release_die "Refusing to reuse or overwrite an existing report path: $report_directory"
  mkdir -m 700 "$report_directory"
  [[ "$(stat -f '%u' "$report_directory")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$report_directory")" == "700" ]] \
    || release_die "Could not create a current-user-owned report directory with mode 0700."
}

create_phase_directory() {
  local phase_name="$1"

  [[ "$phase_name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || release_die "Evidence phase name is not safe: $phase_name"
  ACTIVE_PHASE_DIRECTORY="$REPORT_DIRECTORY/$phase_name"
  [[ ! -e "$ACTIVE_PHASE_DIRECTORY" && ! -L "$ACTIVE_PHASE_DIRECTORY" ]] \
    || release_die "Refusing to overwrite existing phase evidence: $phase_name"
  mkdir -m 700 "$ACTIVE_PHASE_DIRECTORY"
}

base64_text() {
  printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\r\n'
}

evidence_value_from_file() {
  local evidence_path="$1"
  local key="$2"
  local count value

  count="$(/usr/bin/awk -F '\t' -v key="$key" '$1 == key { count += 1 } END { print count + 0 }' "$evidence_path")"
  [[ "$count" == "1" ]] \
    || release_die "Evidence must contain exactly one $key value: $evidence_path"
  value="$(/usr/bin/awk -F '\t' -v key="$key" '$1 == key { print $2 }' "$evidence_path")"
  [[ -n "$value" ]] || release_die "Evidence contains an empty $key value: $evidence_path"
  printf '%s\n' "$value"
}

baseline_value() {
  evidence_value_from_file "$REPORT_DIRECTORY/baseline/evidence.tsv" "$1"
}

write_bundle_manifest() {
  local app_path="$1"
  local output_path="$2"
  local raw_path="${output_path%.tsv}.records.tsv"
  local path_list="${output_path%.tsv}.paths.nul"
  local acl_path="${output_path%.tsv}.acl.txt"
  local item relative encoded_path mode size digest target encoded_target
  local stat_fields owner group flags links device inode encoded_acl

  [[ -d "$app_path" && ! -L "$app_path" ]] \
    || release_die "Bundle manifest source must be a real directory: $app_path"
  /usr/bin/find "$app_path" -print0 > "$path_list" \
    || release_die "Could not enumerate the complete application bundle."
  : > "$raw_path"
  while IFS= read -r -d '' item; do
    if [[ "$item" == "$app_path" ]]; then
      relative="."
    else
      relative="${item#"$app_path"/}"
    fi
    encoded_path="$(base64_text "$relative")"
    stat_fields="$(stat -f '%u %g %f %l %d %i %Lp' "$item")" \
      || release_die "Could not inspect bundle ownership, flags or hard-link identity."
    read -r owner group flags links device inode mode <<< "$stat_fields"
    [[ "$owner" =~ ^[0-9]+$ && "$group" =~ ^[0-9]+$ \
        && "$flags" =~ ^[0-9]+$ && "$links" =~ ^[1-9][0-9]*$ \
        && "$device" =~ ^[0-9]+$ && "$inode" =~ ^[1-9][0-9]*$ \
        && "$mode" =~ ^[0-7]{3,4}$ ]] \
      || release_die "Bundle stat metadata is malformed."
    /bin/ls -lde "$item" > "$acl_path" \
      || release_die "Could not inspect bundle ACL metadata."
    encoded_acl="$(/usr/bin/tail -n +2 "$acl_path" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')"
    if [[ -L "$item" ]]; then
      target="$(readlink "$item")"
      encoded_target="$(base64_text "$target")"
      # macOS does not expose independently enforceable symlink permissions;
      # archive extraction may report them through the target/umask. Bind the
      # path, link type and exact target instead of making a false mode claim.
      printf 'L\t%s\tNA\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\n' \
        "$encoded_path" "$owner" "$group" "$flags" "$links" "$device" "$inode" "$encoded_acl" "$encoded_target" >> "$raw_path"
    elif [[ -f "$item" ]]; then
      size="$(release_file_size "$item")"
      digest="$(release_sha256 "$item")"
      printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$encoded_path" "$mode" "$owner" "$group" "$flags" "$links" "$device" "$inode" "$encoded_acl" "$size" "$digest" >> "$raw_path"
    elif [[ -d "$item" ]]; then
      printf 'D\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t-\n' \
        "$encoded_path" "$mode" "$owner" "$group" "$flags" "$links" "$device" "$inode" "$encoded_acl" >> "$raw_path"
    else
      release_die "App bundle contains an unsupported filesystem object."
    fi
  done < "$path_list"
  /usr/bin/ruby - "$raw_path" "$output_path" <<'RUBY'
source, output = ARGV
rows = File.readlines(source, chomp: true).map { |line| line.split("\t", -1) }
abort("malformed bundle manifest record") unless rows.all? { |row| row.length == 12 }
file_groups = Hash.new { |hash, key| hash[key] = [] }
rows.each do |row|
  next unless row[0] == "F" && Integer(row[6], 10) > 1
  file_groups[[row[7], row[8]]] << row[1]
end
canonical_groups = file_groups.transform_values { |paths| paths.min }
rendered = rows.map do |row|
  kind, path, mode, owner, group, flags, links, device, inode, acl, value1, value2 = row
  hardlink = if kind == "F" && Integer(links, 10) > 1
               canonical_groups.fetch([device, inode])
             else
               "NONE"
             end
  [kind, path, mode, owner, group, flags, links, acl, hardlink, value1, value2].join("\t")
end
File.open(output, "wb", 0o600) { |file| rendered.sort.each { |line| file.puts(line) } }
RUBY
  [[ -s "$output_path" ]] || release_die "Bundle byte manifest is empty."
  chmod 600 "$path_list" "$raw_path" "$acl_path" "$output_path"
}

record_bundle_xattrs() {
  local app_path="$1" output_path="$2" policy="$3" evidence_path="$4" prefix="$5"
  local paths_path="${output_path%.tsv}.paths.nul"
  local names_path="${output_path%.tsv}.names.txt"
  local value_path="${output_path%.tsv}.value.bin"
  local item relative encoded_path name size digest count=0 quarantine_count=0 unexpected_count=0

  [[ "$policy" == "none" || "$policy" == "provenance-only" \
      || "$policy" == "installed-system-only" ]] \
    || release_die "Unknown extended-attribute policy."
  /usr/bin/find "$app_path" -print0 > "$paths_path" \
    || release_die "Could not enumerate bundle paths for extended-attribute verification."
  : > "$output_path"
  : > "$names_path"
  : > "$value_path"
  while IFS= read -r -d '' item; do
    if [[ "$item" == "$app_path" ]]; then relative="."; else relative="${item#"$app_path"/}"; fi
    encoded_path="$(base64_text "$relative")"
    if [[ -L "$item" ]]; then
      /usr/bin/xattr -s "$item" > "$names_path" \
        || release_die "Could not enumerate a bundle symlink's extended attributes."
    else
      /usr/bin/xattr "$item" > "$names_path" \
        || release_die "Could not enumerate bundle extended attributes."
    fi
    while IFS= read -r name || [[ -n "$name" ]]; do
      [[ -n "$name" && "$name" =~ ^[A-Za-z0-9._-]+$ ]] \
        || release_die "Bundle contains an unsafe extended-attribute name."
      [[ "$name" != "com.apple.quarantine" ]] || quarantine_count=$((quarantine_count + 1))
      case "$policy:$name" in
        provenance-only:com.apple.provenance|installed-system-only:com.apple.provenance|installed-system-only:com.apple.macl) ;;
        *) unexpected_count=$((unexpected_count + 1)) ;;
      esac
      if [[ -L "$item" ]]; then
        /usr/bin/xattr -s -p "$name" "$item" > "$value_path" \
          || release_die "Could not read a bundle symlink extended attribute."
      else
        /usr/bin/xattr -p "$name" "$item" > "$value_path" \
          || release_die "Could not read a bundle extended attribute."
      fi
      size="$(release_file_size "$value_path")"
      digest="$(release_sha256 "$value_path")"
      printf 'X\t%s\t%s\t%s\t%s\n' "$encoded_path" "$name" "$size" "$digest" >> "$output_path"
      count=$((count + 1))
    done < "$names_path"
  done < "$paths_path"
  LC_ALL=C /usr/bin/sort -o "$output_path" "$output_path"
  chmod 600 "$paths_path" "$names_path" "$value_path" "$output_path"
  [[ "$quarantine_count" == "0" ]] \
    || release_die "The inspected Ushot bundle still carries com.apple.quarantine."
  [[ "$unexpected_count" == "0" ]] \
    || release_die "The inspected Ushot bundle contains an extended attribute outside the exact policy."
  printf '%s_xattr_policy\t%s\n%s_xattr_record_count\t%s\n%s_quarantine_count\t0\n%s_xattr_manifest_sha256\t%s\n' \
    "$prefix" "$policy" "$prefix" "$count" "$prefix" "$prefix" "$(release_sha256 "$output_path")" \
    >> "$evidence_path"
}

baseline_asset_contract() {
  case "$1" in
    "$BASELINE_DMG_NAME") printf '%s\t%s\n' "$BASELINE_DMG_SIZE" "$BASELINE_DMG_SHA256" ;;
    "$BASELINE_ZIP_NAME") printf '%s\t%s\n' "$BASELINE_ZIP_SIZE" "$BASELINE_ZIP_SHA256" ;;
    "$BASELINE_DSYM_NAME") printf '%s\t%s\n' "$BASELINE_DSYM_SIZE" "$BASELINE_DSYM_SHA256" ;;
    "$BASELINE_MANIFEST_NAME") printf '%s\t%s\n' "$BASELINE_MANIFEST_SIZE" "$BASELINE_MANIFEST_SHA256" ;;
    "$BASELINE_CHECKSUMS_NAME") printf '%s\t%s\n' "$BASELINE_CHECKSUMS_SIZE" "$BASELINE_CHECKSUMS_SHA256" ;;
    *) release_die "Unknown pinned baseline asset name: $1" ;;
  esac
}

validate_published_baseline_assets() {
  local evidence_path="$1"
  local validator_script="$SCRIPT_DIR/validate-release-assets.sh"
  local expected="$ACTIVE_PHASE_DIRECTORY/baseline-asset-expected.txt"
  local actual="$ACTIVE_PHASE_DIRECTORY/baseline-asset-actual.txt"
  local records="$ACTIVE_PHASE_DIRECTORY/baseline-assets.tsv"
  local validator_stdout="$ACTIVE_PHASE_DIRECTORY/baseline-release-validator.stdout"
  local validator_stderr="$ACTIVE_PHASE_DIRECTORY/baseline-release-validator.stderr"
  local name path entry contract expected_size expected_digest mode status
  local validator_script_sha_before validator_script_sha_after

  [[ -f "$validator_script" && ! -L "$validator_script" \
      && "$(stat -f '%u' "$validator_script")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$validator_script")" == "755" ]] \
    || release_die "The hardened release-asset validator must be a current-user-owned mode-0755 regular source file."

  BASELINE_ASSETS_DIRECTORY="$(require_canonical_directory "$BASELINE_ASSETS_DIRECTORY" "Published v0.1.3 asset directory")"
  [[ "$(stat -f '%u' "$BASELINE_ASSETS_DIRECTORY")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$BASELINE_ASSETS_DIRECTORY")" == "700" ]] \
    || release_die "Published baseline asset directory must be current-user-owned mode 0700."
  printf '%s\n' \
    "$BASELINE_DMG_NAME" "$BASELINE_ZIP_NAME" "$BASELINE_DSYM_NAME" \
    "$BASELINE_MANIFEST_NAME" "$BASELINE_CHECKSUMS_NAME" \
    | LC_ALL=C /usr/bin/sort > "$expected"
  : > "$actual"
  while IFS= read -r -d '' entry; do
    name="${entry#"$BASELINE_ASSETS_DIRECTORY"/}"
    [[ "$name" != "$entry" && "$name" =~ ^[A-Za-z0-9._-]+$ ]] \
      || release_die "Published baseline directory contains an unsafe path."
    printf '%s\n' "$name" >> "$actual"
  done < <(/usr/bin/find "$BASELINE_ASSETS_DIRECTORY" -mindepth 1 -maxdepth 1 -type f -print0)
  LC_ALL=C /usr/bin/sort -o "$actual" "$actual"
  /usr/bin/cmp -s "$expected" "$actual" \
    || release_die "Published baseline directory must contain exactly the five pinned v0.1.3 assets."
  [[ "$(/usr/bin/find "$BASELINE_ASSETS_DIRECTORY" -mindepth 1 -maxdepth 1 ! -type f -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == "0" ]] \
    || release_die "Published baseline asset directory contains a non-regular entry."

  : > "$records"
  while IFS= read -r name; do
    path="$(require_canonical_file "$BASELINE_ASSETS_DIRECTORY/$name" "published baseline asset")"
    [[ "$(stat -f '%u' "$path")" == "$CURRENT_UID" ]] \
      || release_die "Published baseline assets must be owned by the current user."
    mode="$(stat -f '%Lp' "$path")"
    (( (8#$mode & 0022) == 0 )) \
      || release_die "Published baseline assets must not be group/world writable."
    contract="$(baseline_asset_contract "$name")"
    IFS=$'\t' read -r expected_size expected_digest <<< "$contract"
    [[ "$(release_file_size "$path")" == "$expected_size" \
        && "$(release_sha256 "$path")" == "$expected_digest" ]] \
      || release_die "Published baseline asset differs from the pinned GitHub v0.1.3 bytes: $name"
    printf '%s\t%s\t%s\t%s\n' "$name" "$expected_size" "$expected_digest" "$mode" >> "$records"
  done < "$expected"
  chmod 600 "$expected" "$actual" "$records"

  validator_script_sha_before="$(release_sha256 "$validator_script")"
  set +e
  "$validator_script" \
    --directory "$BASELINE_ASSETS_DIRECTORY" \
    --mode public-adhoc \
    --version "$BASELINE_VERSION" \
    --build-number "$BASELINE_BUILD" \
    --tag "$BASELINE_TAG" \
    > "$validator_stdout" 2> "$validator_stderr"
  status=$?
  set -e
  validator_script_sha_after="$(release_sha256 "$validator_script")"
  chmod 600 "$validator_stdout" "$validator_stderr"
  [[ "$status" == "0" ]] \
    || release_die "Hardened release-asset validation rejected the exact pinned public v0.1.3 assets."
  [[ "$validator_script_sha_after" == "$validator_script_sha_before" ]] \
    || release_die "The hardened release-asset validator changed while validating the baseline."
  printf '%b\n' \
    "baseline_assets_directory\t$BASELINE_ASSETS_DIRECTORY" \
    "baseline_release_tag\t$BASELINE_TAG" \
    "baseline_release_version\t$BASELINE_VERSION" \
    "baseline_release_build\t$BASELINE_BUILD" \
    'baseline_release_asset_count\t5' \
    'baseline_release_asset_pin_source\tIMMUTABLE_GITHUB_RELEASE_V0.1.3_API_AND_LOCAL_BYTES_INDEPENDENTLY_CONFIRMED_2026-08-06' \
    "baseline_asset_records_sha256\t$(release_sha256 "$records")" \
    "baseline_release_validator_script_sha256\t$validator_script_sha_before" \
    'baseline_hardened_release_asset_validation\tPASS' \
    >> "$evidence_path"
}

write_fixture_expected_paths() {
  local output="$1"
  local case_name

  : > "$output"
  for case_name in \
    normal \
    tampered-archive \
    short-version-mismatch \
    build-number-mismatch \
    short-and-build-mismatch \
    duplicate-build-metadata \
    oversized-signed-feed; do
    printf '%s/appcast.xml\n%s/%s\n' "$case_name" "$case_name" "$ARCHIVE_NAME" >> "$output"
  done
  printf 'fixture-manifest.json\n' >> "$output"
  LC_ALL=C /usr/bin/sort -o "$output" "$output"
  chmod 600 "$output"
}

validate_fixture_tree_and_checksums() {
  local expected_paths="$ACTIVE_PHASE_DIRECTORY/fixture-expected-paths.txt"
  local expected_all_paths="$ACTIVE_PHASE_DIRECTORY/fixture-expected-all-files.txt"
  local actual_paths="$ACTIVE_PHASE_DIRECTORY/fixture-actual-files.txt"
  local expected_directories="$ACTIVE_PHASE_DIRECTORY/fixture-expected-directories.txt"
  local actual_directories="$ACTIVE_PHASE_DIRECTORY/fixture-actual-directories.txt"
  local checksum_paths="$ACTIVE_PHASE_DIRECTORY/fixture-checksum-paths.txt"
  local line digest relative actual_digest path mode
  local count=0

  write_fixture_expected_paths "$expected_paths"
  { /bin/cat "$expected_paths"; printf 'SHA256SUMS.txt\n'; } \
    | LC_ALL=C /usr/bin/sort > "$expected_all_paths"
  : > "$actual_paths"
  while IFS= read -r -d '' path; do
    relative="${path#"$FIXTURES_ROOT"/}"
    [[ "$relative" != "$path" \
        && "$relative" =~ ^[A-Za-z0-9._/-]+$ \
        && "$relative" != *//* \
        && "$(stat -f '%u' "$path")" == "$CURRENT_UID" \
        && "$(stat -f '%Lp' "$path")" == "600" ]] \
      || release_die "Fixture tree contains a noncanonical or control-character path."
    printf '%s\n' "$relative" >> "$actual_paths"
  done < <(/usr/bin/find "$FIXTURES_ROOT" -type f -print0)
  LC_ALL=C /usr/bin/sort -o "$actual_paths" "$actual_paths"
  /usr/bin/cmp -s "$expected_all_paths" "$actual_paths" \
    || release_die "Fixture root file allowlist does not exactly match the seven-case schema."
  [[ "$(/usr/bin/find "$FIXTURES_ROOT" -type l -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == "0" ]] \
    || release_die "Fixture root must not contain symbolic links."
  [[ "$(/usr/bin/find "$FIXTURES_ROOT" ! -type f ! -type d ! -type l -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == "0" ]] \
    || release_die "Fixture root contains a socket, device, FIFO or another unsupported object."
  printf '%s\n' \
    . normal tampered-archive short-version-mismatch build-number-mismatch \
    short-and-build-mismatch duplicate-build-metadata oversized-signed-feed \
    | LC_ALL=C /usr/bin/sort > "$expected_directories"
  : > "$actual_directories"
  while IFS= read -r -d '' path; do
    if [[ "$path" == "$FIXTURES_ROOT" ]]; then relative="."; else relative="${path#"$FIXTURES_ROOT"/}"; fi
    mode="$(stat -f '%Lp' "$path")"
    [[ ( "$relative" == "." || "$relative" =~ ^[a-z0-9][a-z0-9-]*$ ) \
        && "$(stat -f '%u' "$path")" == "$CURRENT_UID" \
        && "$mode" == "700" ]] \
      || release_die "Fixture tree contains an unexpected or non-private directory."
    printf '%s\n' "$relative" >> "$actual_directories"
  done < <(/usr/bin/find "$FIXTURES_ROOT" -type d -print0)
  LC_ALL=C /usr/bin/sort -o "$actual_directories" "$actual_directories"
  /usr/bin/cmp -s "$expected_directories" "$actual_directories" \
    || release_die "Fixture root directory allowlist does not exactly match the seven-case schema."

  : > "$checksum_paths"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([0-9a-f]{64})\ \ ([A-Za-z0-9._/-]+)$ ]] \
      || release_die "SHA256SUMS.txt contains a malformed or unsafe entry."
    digest="${BASH_REMATCH[1]}"
    relative="${BASH_REMATCH[2]}"
    /usr/bin/grep -Fx "$relative" "$expected_paths" >/dev/null \
      || release_die "SHA256SUMS.txt contains an unexpected path: $relative"
    [[ "$(/usr/bin/grep -Fxc "$relative" "$checksum_paths")" == "0" ]] \
      || release_die "SHA256SUMS.txt contains a duplicate path: $relative"
    printf '%s\n' "$relative" >> "$checksum_paths"
    actual_digest="$(release_sha256 "$FIXTURES_ROOT/$relative")"
    [[ "$actual_digest" == "$digest" ]] \
      || release_die "Fixture checksum mismatch: $relative"
    count=$((count + 1))
  done < "$FIXTURE_CHECKSUMS"
  LC_ALL=C /usr/bin/sort -o "$checksum_paths" "$checksum_paths"
  [[ "$count" == "15" ]] \
    || release_die "SHA256SUMS.txt must contain exactly fifteen fixture/manifest entries."
  /usr/bin/cmp -s "$expected_paths" "$checksum_paths" \
    || release_die "SHA256SUMS.txt does not cover the exact fixture allowlist."
  chmod 600 "$expected_all_paths" "$actual_paths" "$expected_directories" "$actual_directories" "$checksum_paths"
}

expected_case_contract() {
  case "$CASE_LABEL" in
    normal)
      FIXTURE_XML_POLICY="accepted"
      FIXTURE_XML_REJECTION_CATEGORY=""
      FIXTURE_ARCHIVE_EDDSA="verified"
      FIXTURE_BUNDLE_VERSION="$USHOT_FIRST_FEED_VERSION"
      FIXTURE_BUNDLE_BUILD="$USHOT_FIRST_FEED_BUILD"
      FIXTURE_EXPECTED_RESULT="atomic replacement and relaunch"
      ;;
    tampered-archive)
      FIXTURE_XML_POLICY="accepted"
      FIXTURE_XML_REJECTION_CATEGORY=""
      FIXTURE_ARCHIVE_EDDSA="rejection-proven"
      FIXTURE_BUNDLE_VERSION="$USHOT_FIRST_FEED_VERSION"
      FIXTURE_BUNDLE_BUILD="$USHOT_FIRST_FEED_BUILD"
      FIXTURE_EXPECTED_RESULT="archive EdDSA rejection before extraction"
      ;;
    short-version-mismatch)
      FIXTURE_XML_POLICY="accepted"
      FIXTURE_XML_REJECTION_CATEGORY=""
      FIXTURE_ARCHIVE_EDDSA="verified"
      FIXTURE_BUNDLE_VERSION="0.1.5"
      FIXTURE_BUNDLE_BUILD="$USHOT_FIRST_FEED_BUILD"
      FIXTURE_EXPECTED_RESULT="post-extraction exact-version rejection"
      ;;
    build-number-mismatch)
      FIXTURE_XML_POLICY="accepted"
      FIXTURE_XML_REJECTION_CATEGORY=""
      FIXTURE_ARCHIVE_EDDSA="verified"
      FIXTURE_BUNDLE_VERSION="$USHOT_FIRST_FEED_VERSION"
      FIXTURE_BUNDLE_BUILD="6"
      FIXTURE_EXPECTED_RESULT="post-extraction exact-build rejection"
      ;;
    short-and-build-mismatch)
      FIXTURE_XML_POLICY="accepted"
      FIXTURE_XML_REJECTION_CATEGORY=""
      FIXTURE_ARCHIVE_EDDSA="verified"
      FIXTURE_BUNDLE_VERSION="0.1.5"
      FIXTURE_BUNDLE_BUILD="6"
      FIXTURE_EXPECTED_RESULT="post-extraction exact-version-and-build rejection"
      ;;
    duplicate-build-metadata)
      FIXTURE_XML_POLICY="rejection-proven"
      FIXTURE_XML_REJECTION_CATEGORY="invalid-version-identity"
      FIXTURE_ARCHIVE_EDDSA="verified"
      FIXTURE_BUNDLE_VERSION="$USHOT_FIRST_FEED_VERSION"
      FIXTURE_BUNDLE_BUILD="$USHOT_FIRST_FEED_BUILD"
      FIXTURE_EXPECTED_RESULT="authenticated raw-XML rejection before item parsing"
      ;;
    oversized-signed-feed)
      FIXTURE_XML_POLICY="rejection-proven"
      FIXTURE_XML_REJECTION_CATEGORY="oversized-signed-feed"
      FIXTURE_ARCHIVE_EDDSA="verified"
      FIXTURE_BUNDLE_VERSION="$USHOT_FIRST_FEED_VERSION"
      FIXTURE_BUNDLE_BUILD="$USHOT_FIRST_FEED_BUILD"
      FIXTURE_EXPECTED_RESULT=""
      ;;
    *) release_die "Unknown transition fixture case: $CASE_LABEL" ;;
  esac
}

validate_fixture_manifest_case() {
  local selected="$ACTIVE_PHASE_DIRECTORY/fixture-selected.json"
  local manifest_feed_path manifest_archive_path manifest_value expected_feed_path expected_archive_path
  local fixture_script="$SCRIPT_DIR/prepare-update-transition-fixtures.sh"
  local validate_appcast_source="$SCRIPT_DIR/validate-appcast.sh"
  local release_notes_source="$SCRIPT_DIR/../updates/release-notes/0.1.4.md"
  local fixture_script_sha release_common_sha validate_appcast_sha release_notes_sha public_key_fingerprint manifest_source_mode

  expected_case_contract
  for manifest_value in "$fixture_script" "$validate_appcast_source" "$release_notes_source"; do
    manifest_source_mode="$(stat -f '%Lp' "$manifest_value" 2>/dev/null || printf 'invalid')"
    [[ -f "$manifest_value" && ! -L "$manifest_value" \
        && "$(stat -f '%u' "$manifest_value")" == "$CURRENT_UID" \
        && "$manifest_source_mode" =~ ^[0-7]{3,4}$ ]] \
      || release_die "A fixture-manifest source is missing, symbolic, unexpectedly owned or writable: $manifest_value"
    (( (8#$manifest_source_mode & 0022) == 0 )) \
      || release_die "A fixture-manifest source is group- or world-writable: $manifest_value"
  done
  [[ "$(stat -f '%Lp' "$fixture_script")" == "755" ]] \
    || release_die "The reviewed fixture-preparation script must have exact mode 0755."
  fixture_script_sha="$(release_sha256 "$fixture_script")"
  release_common_sha="$(release_sha256 "$SCRIPT_DIR/release-common.sh")"
  validate_appcast_sha="$(release_sha256 "$validate_appcast_source")"
  release_notes_sha="$(release_sha256 "$release_notes_source")"
  public_key_fingerprint="$(
    printf '%s' "$USHOT_SPARKLE_PUBLIC_ED_KEY" \
      | /usr/bin/base64 -D \
      | /usr/bin/shasum -a 256 \
      | /usr/bin/awk '{print $1}'
  )"
  [[ "$public_key_fingerprint" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Could not derive the embedded Sparkle public-key fingerprint."
  [[ "$fixture_script_sha" == "$EXPECTED_FIXTURE_SCRIPT_SHA256" \
      && "$release_common_sha" == "$EXPECTED_RELEASE_COMMON_SHA256" \
      && "$validate_appcast_sha" == "$EXPECTED_VALIDATE_APPCAST_SHA256" \
      && "$release_notes_sha" == "$EXPECTED_RELEASE_NOTES_SHA256" ]] \
    || release_die "A final2 fixture source differs from its independently reviewed immutable digest."
  /usr/bin/jq -e \
    --arg sourceVersion "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" \
    --arg sourceBuild "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" \
    --arg targetVersion "$USHOT_FIRST_FEED_VERSION" \
    --arg targetBuild "$USHOT_FIRST_FEED_BUILD" \
    --arg tag "v$USHOT_FIRST_FEED_VERSION" \
    --arg appcastURL "$USHOT_APPCAST_URL" \
    --arg enclosureURL "https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/v$USHOT_FIRST_FEED_VERSION/$ARCHIVE_NAME" \
    --arg archiveName "$ARCHIVE_NAME" \
    --arg sparkleVersion "$USHOT_SPARKLE_VERSION" \
    --arg sparkleArchiveSHA256 "$USHOT_SPARKLE_ARCHIVE_SHA256" \
    --arg keyAccount "$USHOT_SPARKLE_KEY_ACCOUNT" \
    --arg publicKeyFingerprintSHA256 "$public_key_fingerprint" \
    --arg fixtureScriptSHA256 "$EXPECTED_FIXTURE_SCRIPT_SHA256" \
    --arg frozenBundleManifestSHA256 "$EXPECTED_FROZEN_BUNDLE_MANIFEST_SHA256" \
    --arg reviewedSourceManifestSHA256 "$EXPECTED_REVIEWED_SOURCE_MANIFEST_SHA256" \
    --arg releaseCommonSHA256 "$EXPECTED_RELEASE_COMMON_SHA256" \
    --arg validateAppcastSHA256 "$EXPECTED_VALIDATE_APPCAST_SHA256" \
    --arg generateAppcastSHA256 "$EXPECTED_GENERATE_APPCAST_SHA256" \
    --arg generateKeysSHA256 "$EXPECTED_GENERATE_KEYS_SHA256" \
    --arg signUpdateSHA256 "$EXPECTED_SIGN_UPDATE_SHA256" \
    --arg authenticatedValidatorSHA256 "$EXPECTED_AUTHENTICATED_APPCAST_VALIDATOR_SHA256" \
    --arg publicKeyDeriverSHA256 "$EXPECTED_PUBLIC_KEY_DERIVER_SHA256" \
    --arg embeddedPublicKeyVerifierSHA256 "$EXPECTED_EMBEDDED_PUBLIC_KEY_VERIFIER_SHA256" \
    --arg releaseNotesSHA256 "$EXPECTED_RELEASE_NOTES_SHA256" \
    --arg candidateDMGSHA256 "$EXPECTED_CANDIDATE_DMG_SHA256" \
    --arg candidateZIPSHA256 "$EXPECTED_CANDIDATE_ZIP_SHA256" \
    --arg candidateDSYMSHA256 "$EXPECTED_CANDIDATE_DSYM_SHA256" \
    --arg candidateManifestSHA256 "$EXPECTED_CANDIDATE_MANIFEST_SHA256" \
    --arg candidateChecksumsSHA256 "$EXPECTED_CANDIDATE_CHECKSUMS_SHA256" \
    --arg mismatchVersion "0.1.5" \
    --arg mismatchBuild "6" \
    --argjson maximumAuthenticatedPrefixBytes "$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES" \
    --argjson maximumSignedFeedWireBytes "$(( USHOT_MAX_AUTHENTICATED_APPCAST_BYTES + 512 ))" \
    --argjson loopbackMaximumFeedBytes "$MAX_FIXTURE_FEED_BYTES" '
      def exact_keys($expected): keys == ($expected | sort);
      def sha256: type == "string" and test("^[0-9a-f]{64}$");
      def accepted_feed($name):
        exact_keys(["path","sha256","edDSA","authenticatedXMLPolicy"]) and
        .path == ($name + "/appcast.xml") and (.sha256 | sha256);
      def accepted_feed_contract($name):
        accepted_feed($name) and .edDSA == "verified" and .authenticatedXMLPolicy == "accepted";
      def verified_archive($name; $version; $build):
        exact_keys(["path","sha256","edDSA","bundleVersion","bundleBuild"]) and
        .path == ($name + "/" + $archiveName) and (.sha256 | sha256) and
        .edDSA == "verified" and .bundleVersion == $version and .bundleBuild == $build;
      exact_keys(["schemaVersion","purpose","source","advertisedTarget","requests","tools","reviewedSources","candidateInputs","invariants","fixtures"]) and
      .schemaVersion == 2 and
      .purpose == "isolated Ushot 0.1.3 to 0.1.4 update-transition evidence" and
      (.source | exact_keys(["version","build"]) and .version == $sourceVersion and .build == $sourceBuild) and
      (.advertisedTarget | exact_keys(["version","build","tag"]) and .version == $targetVersion and .build == $targetBuild and .tag == $tag) and
      (.requests | exact_keys(["appcastURL","enclosureURL"]) and .appcastURL == $appcastURL and .enclosureURL == $enclosureURL) and
      .tools == {
        sparkleVersion: $sparkleVersion,
        sparkleReleaseArchiveSHA256: $sparkleArchiveSHA256,
        sparkleGenerateAppcastSHA256: $generateAppcastSHA256,
        sparkleGenerateKeysSHA256: $generateKeysSHA256,
        sparkleSignUpdateSHA256: $signUpdateSHA256,
        authenticatedAppcastValidatorSHA256: $authenticatedValidatorSHA256,
        publicKeyDeriverSHA256: $publicKeyDeriverSHA256,
        embeddedPublicKeyVerifierSHA256: $embeddedPublicKeyVerifierSHA256,
        keySource: "keychain",
        signingPublicKeyIdentityVerified: true,
        keyAccount: $keyAccount,
        publicKeyFingerprintSHA256: $publicKeyFingerprintSHA256,
        archiveAndFeedVerification: "independent embedded-public-key verifier"
      } and
      .reviewedSources == {
        externalReviewedSourceManifestSHA256: $reviewedSourceManifestSHA256,
        frozenBundleManifestSHA256: $frozenBundleManifestSHA256,
        fixtureScriptSHA256: $fixtureScriptSHA256,
        releaseCommonSHA256: $releaseCommonSHA256,
        validateAppcastSHA256: $validateAppcastSHA256
      } and
      .candidateInputs == {
        exactAssetCount: 5,
        assets: [
          {name: "Ushot-0.1.4-arm64.dmg", sha256: $candidateDMGSHA256},
          {name: "Ushot-0.1.4-arm64.zip", sha256: $candidateZIPSHA256},
          {name: "Ushot-0.1.4-arm64.dSYM.zip", sha256: $candidateDSYMSHA256},
          {name: "Ushot-0.1.4-arm64.release-manifest.json", sha256: $candidateManifestSHA256},
          {name: "SHA256SUMS.txt", sha256: $candidateChecksumsSHA256}
        ],
        releaseNotesSHA256: $releaseNotesSHA256
      } and
      (.invariants |
        exact_keys(["privateKeyWrittenByThisScript","deployedOrPublished","outputMode","archiveName"]) and
        .privateKeyWrittenByThisScript == false and
        .deployedOrPublished == false and
        .outputMode == "0700" and
        .archiveName == $archiveName) and
      (.fixtures | type == "array" and length == 7) and
      ([.fixtures[].name] == [
        "normal",
        "tampered-archive",
        "short-version-mismatch",
        "build-number-mismatch",
        "short-and-build-mismatch",
        "duplicate-build-metadata",
        "oversized-signed-feed"
      ]) and
      (.fixtures[0] |
        exact_keys(["name","feed","archive","expectedClientResult"]) and
        .name == "normal" and
        (.feed | accepted_feed_contract("normal")) and
        (.archive | verified_archive("normal"; $targetVersion; $targetBuild)) and
        .expectedClientResult == "atomic replacement and relaunch") and
      (.fixtures[1] |
        exact_keys(["name","feed","archive","expectedClientResult"]) and
        .name == "tampered-archive" and
        (.feed | accepted_feed_contract("tampered-archive")) and
        (.archive |
          exact_keys(["path","sha256","edDSA","sameByteLengthAsNormal","bundleVersion","bundleBuild","bundleAdHocSignature"]) and
          .path == ("tampered-archive/" + $archiveName) and (.sha256 | sha256) and
          .edDSA == "rejection-proven" and .sameByteLengthAsNormal == true and
          .bundleVersion == $targetVersion and .bundleBuild == $targetBuild and
          .bundleAdHocSignature == "verified-after-final-archive-extraction") and
        .expectedClientResult == "archive EdDSA rejection before extraction") and
      (.fixtures[2] |
        exact_keys(["name","feed","archive","expectedClientResult"]) and
        .name == "short-version-mismatch" and
        (.feed | accepted_feed_contract("short-version-mismatch")) and
        (.archive | verified_archive("short-version-mismatch"; $mismatchVersion; $targetBuild)) and
        .expectedClientResult == "post-extraction exact-version rejection") and
      (.fixtures[3] |
        exact_keys(["name","feed","archive","expectedClientResult"]) and
        .name == "build-number-mismatch" and
        (.feed | accepted_feed_contract("build-number-mismatch")) and
        (.archive | verified_archive("build-number-mismatch"; $targetVersion; $mismatchBuild)) and
        .expectedClientResult == "post-extraction exact-build rejection") and
      (.fixtures[4] |
        exact_keys(["name","feed","archive","expectedClientResult"]) and
        .name == "short-and-build-mismatch" and
        (.feed | accepted_feed_contract("short-and-build-mismatch")) and
        (.archive | verified_archive("short-and-build-mismatch"; $mismatchVersion; $mismatchBuild)) and
        .expectedClientResult == "post-extraction exact-version-and-build rejection") and
      (.fixtures[5] |
        exact_keys(["name","feed","archive","expectedClientResult"]) and
        .name == "duplicate-build-metadata" and
        (.feed |
          exact_keys(["path","sha256","edDSA","authenticatedXMLPolicy","rejectionCategory"]) and
          .path == "duplicate-build-metadata/appcast.xml" and (.sha256 | sha256) and
          .edDSA == "verified" and .authenticatedXMLPolicy == "rejection-proven" and
          .rejectionCategory == "invalid-version-identity") and
        (.archive | verified_archive("duplicate-build-metadata"; $targetVersion; $targetBuild)) and
        .expectedClientResult == "authenticated raw-XML rejection before item parsing") and
      (.fixtures[6] |
        exact_keys(["name","feed","archive","expectedClientResults"]) and
        .name == "oversized-signed-feed" and
        (.feed |
          exact_keys(["path","sha256","edDSA","verificationMode","authenticatedXMLPolicy","rejectionCategory","authenticatedPrefixBytes","maximumAuthenticatedPrefixBytes","signedFeedBytes","maximumSignedFeedWireBytes","loopbackMaximumFeedBytes"]) and
          .path == "oversized-signed-feed/appcast.xml" and (.sha256 | sha256) and
          .edDSA == "verified" and .verificationMode == "cryptographic-only-2MiB" and
          .authenticatedXMLPolicy == "rejection-proven" and
          .rejectionCategory == "oversized-signed-feed" and
          (.authenticatedPrefixBytes | type == "number" and floor == .) and
          .maximumAuthenticatedPrefixBytes == $maximumAuthenticatedPrefixBytes and
          .authenticatedPrefixBytes > .maximumAuthenticatedPrefixBytes and
          (.signedFeedBytes | type == "number" and floor == .) and
          # Official Sparkle signed-feed trailers are variable-length HTML comment
          # blocks (often far under 512). The 512-byte figure is the host wire
          # allowance above the authenticated prefix, not a fixed trailer size.
          (.signedFeedBytes > .authenticatedPrefixBytes) and
          ((.signedFeedBytes - .authenticatedPrefixBytes) <= 512) and
          .maximumSignedFeedWireBytes == $maximumSignedFeedWireBytes and
          .signedFeedBytes > .maximumSignedFeedWireBytes and
          .loopbackMaximumFeedBytes == $loopbackMaximumFeedBytes and
          .signedFeedBytes <= .loopbackMaximumFeedBytes) and
        (.archive | verified_archive("oversized-signed-feed"; $targetVersion; $targetBuild)) and
        (.expectedClientResults |
          exact_keys(["contentLength","chunked"]) and
          .contentLength == "declared Content-Length rejection before body acceptance or XML parsing" and
          .chunked == "incremental wire-size rejection before signed-feed or XML parsing")) and
      ([.candidateInputs.assets[] | select(.name == $archiveName)] as $candidateArchives |
        ($candidateArchives | length) == 1 and
        $candidateArchives[0].sha256 == .fixtures[0].archive.sha256) and
      .fixtures[1].feed.sha256 == .fixtures[0].feed.sha256 and
      .fixtures[1].archive.sha256 != .fixtures[0].archive.sha256 and
      .fixtures[5].archive.sha256 == .fixtures[0].archive.sha256 and
      .fixtures[6].archive.sha256 == .fixtures[0].archive.sha256
    ' "$FIXTURE_MANIFEST" >/dev/null \
    || release_die "fixture-manifest.json does not match the exact schema-v2 0.1.3 to 0.1.4 seven-case contract."

  /usr/bin/jq -ce --arg case "$CASE_LABEL" '
      [.fixtures[] | select(.name == $case)] as $matches |
      if ($matches | length) == 1 then $matches[0] else error("case cardinality") end
    ' "$FIXTURE_MANIFEST" > "$selected" \
    || release_die "fixture-manifest.json does not contain exactly one selected case."
  chmod 600 "$selected"

  expected_feed_path="$CASE_LABEL/appcast.xml"
  expected_archive_path="$CASE_LABEL/$ARCHIVE_NAME"
  manifest_feed_path="$(/usr/bin/jq -er '.feed.path' "$selected")"
  manifest_archive_path="$(/usr/bin/jq -er '.archive.path' "$selected")"
  [[ "$manifest_feed_path" == "$expected_feed_path" \
      && "$manifest_archive_path" == "$expected_archive_path" ]] \
    || release_die "Selected fixture paths do not exactly match the case directory."

  FIXTURE_FEED_SHA256="$(/usr/bin/jq -er '.feed.sha256' "$selected")"
  FIXTURE_ARCHIVE_SHA256="$(/usr/bin/jq -er '.archive.sha256' "$selected")"
  [[ "$FIXTURE_FEED_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$FIXTURE_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Selected manifest fixture hashes are malformed."
  [[ "$(release_sha256 "$FIXTURES_ROOT/$manifest_feed_path")" == "$FIXTURE_FEED_SHA256" \
      && "$(release_sha256 "$FIXTURES_ROOT/$manifest_archive_path")" == "$FIXTURE_ARCHIVE_SHA256" ]] \
    || release_die "Selected fixture bytes do not match their exact manifest entry."

  manifest_value="$(/usr/bin/jq -er '.feed.edDSA' "$selected")"
  [[ "$manifest_value" == "verified" ]] \
    || release_die "Every selected fixture feed must declare verified EdDSA."
  manifest_value="$(/usr/bin/jq -er '.feed.authenticatedXMLPolicy' "$selected")"
  [[ "$manifest_value" == "$FIXTURE_XML_POLICY" ]] \
    || release_die "Selected fixture authenticated-XML status differs from the case contract."
  manifest_value="$(/usr/bin/jq -er '.archive.edDSA' "$selected")"
  [[ "$manifest_value" == "$FIXTURE_ARCHIVE_EDDSA" ]] \
    || release_die "Selected fixture archive EdDSA status differs from the case contract."

  if [[ -n "$FIXTURE_XML_REJECTION_CATEGORY" ]]; then
    [[ "$(/usr/bin/jq -er '.feed.rejectionCategory' "$selected")" == "$FIXTURE_XML_REJECTION_CATEGORY" ]] \
      || release_die "Selected fixture has the wrong authenticated-XML rejection category."
  fi
  if [[ -n "$FIXTURE_BUNDLE_VERSION" ]]; then
    [[ "$(/usr/bin/jq -er '.archive.bundleVersion' "$selected")" == "$FIXTURE_BUNDLE_VERSION" \
        && "$(/usr/bin/jq -er '.archive.bundleBuild' "$selected")" == "$FIXTURE_BUNDLE_BUILD" ]] \
      || release_die "Selected fixture archive identity differs from its case contract."
  fi
  if [[ -n "$FIXTURE_EXPECTED_RESULT" ]]; then
    [[ "$(/usr/bin/jq -er '.expectedClientResult' "$selected")" == "$FIXTURE_EXPECTED_RESULT" ]] \
      || release_die "Selected fixture client result differs from its case contract."
  fi
  if [[ "$CASE_LABEL" == "tampered-archive" ]]; then
    [[ "$(/usr/bin/jq -er '.archive.sameByteLengthAsNormal' "$selected")" == "true" \
        && "$(/usr/bin/jq -er '.archive.bundleAdHocSignature' "$selected")" == "verified-after-final-archive-extraction" ]] \
      || release_die "Tampered archive must prove equal byte length to the normal archive."
  fi

  FEED_FIXTURE="$(require_canonical_file "$FIXTURES_ROOT/$manifest_feed_path" "selected feed fixture")"
  ARCHIVE_FIXTURE="$(require_canonical_file "$FIXTURES_ROOT/$manifest_archive_path" "selected archive fixture")"
  FIXTURE_FEED_SIZE="$(release_file_size "$FEED_FIXTURE")"
  FIXTURE_ARCHIVE_SIZE="$(release_file_size "$ARCHIVE_FIXTURE")"
  (( FIXTURE_FEED_SIZE <= MAX_FIXTURE_FEED_BYTES )) \
    || release_die "Selected feed fixture exceeds the verifier's bounded fixture limit."
  (( FIXTURE_ARCHIVE_SIZE <= MAX_FIXTURE_ARCHIVE_BYTES )) \
    || release_die "Selected archive fixture exceeds the verifier's bounded fixture limit."
  if [[ "$CASE_LABEL" == "tampered-archive" ]]; then
    [[ "$FIXTURE_ARCHIVE_SIZE" == "$(release_file_size "$FIXTURES_ROOT/normal/$ARCHIVE_NAME")" \
        && "$FIXTURE_ARCHIVE_SHA256" != "$(release_sha256 "$FIXTURES_ROOT/normal/$ARCHIVE_NAME")" ]] \
      || release_die "Tampered archive bytes do not prove an equal-length, byte-distinct mutation of normal."
  elif [[ "$CASE_LABEL" == "oversized-signed-feed" ]]; then
    [[ "$(/usr/bin/jq -er '.feed.verificationMode' "$selected")" == "cryptographic-only-2MiB" \
        && "$(/usr/bin/jq -er '.feed.signedFeedBytes' "$selected")" == "$FIXTURE_FEED_SIZE" \
        && "$(/usr/bin/jq -er '.feed.maximumAuthenticatedPrefixBytes' "$selected")" == "$USHOT_MAX_AUTHENTICATED_APPCAST_BYTES" \
        && "$(/usr/bin/jq -er '.feed.maximumSignedFeedWireBytes' "$selected")" == "$(( USHOT_MAX_AUTHENTICATED_APPCAST_BYTES + 512 ))" \
        && "$(/usr/bin/jq -er '.feed.loopbackMaximumFeedBytes' "$selected")" == "$MAX_FIXTURE_FEED_BYTES" ]] \
      || release_die "Oversized fixture byte counts do not match the exact selected feed and runtime ceilings."
    manifest_value="$(/usr/bin/jq -er --arg mode "$FEED_TRANSFER_MODE" '.expectedClientResults[if $mode == "normal" then "contentLength" else "chunked" end]' "$selected")"
    if [[ "$FEED_TRANSFER_MODE" == "normal" ]]; then
      [[ "$manifest_value" == "declared Content-Length rejection before body acceptance or XML parsing" ]] \
        || release_die "Oversized declared-length fixture has the wrong expected client result."
    else
      [[ "$manifest_value" == "incremental wire-size rejection before signed-feed or XML parsing" ]] \
        || release_die "Oversized chunked fixture has the wrong expected client result."
    fi
  fi
}

validate_fixture_root_and_case() {
  local evidence_path="$1"
  local root_owner root_mode manifest_sha_before checksums_sha_before

  FIXTURES_ROOT="$(require_canonical_directory "$FIXTURES_ROOT" "Fixture root")"
  root_owner="$(stat -f '%u' "$FIXTURES_ROOT")"
  root_mode="$(stat -f '%Lp' "$FIXTURES_ROOT")"
  [[ "$root_owner" == "$CURRENT_UID" && "$root_mode" == "700" ]] \
    || release_die "Fixture root must be current-user-owned with mode 0700."
  FIXTURE_MANIFEST="$(require_canonical_file "$FIXTURES_ROOT/fixture-manifest.json" "fixture manifest")"
  FIXTURE_CHECKSUMS="$(require_canonical_file "$FIXTURES_ROOT/SHA256SUMS.txt" "fixture checksums")"
  manifest_sha_before="$(release_sha256 "$FIXTURE_MANIFEST")"
  checksums_sha_before="$(release_sha256 "$FIXTURE_CHECKSUMS")"
  validate_fixture_tree_and_checksums
  validate_fixture_manifest_case
  FIXTURE_MANIFEST_SHA256="$(release_sha256 "$FIXTURE_MANIFEST")"
  FIXTURE_CHECKSUMS_SHA256="$(release_sha256 "$FIXTURE_CHECKSUMS")"
  [[ "$FIXTURE_MANIFEST_SHA256" == "$manifest_sha_before" \
      && "$FIXTURE_CHECKSUMS_SHA256" == "$checksums_sha_before" ]] \
    || release_die "Fixture manifest or checksum index changed during admission."
  printf '%b\n' \
    "fixtures_root\t$FIXTURES_ROOT" \
    "fixture_case\t$CASE_LABEL" \
    'fixture_manifest_schema_version\t2' \
    "fixture_manifest_sha256\t$FIXTURE_MANIFEST_SHA256" \
    "fixture_checksums_sha256\t$FIXTURE_CHECKSUMS_SHA256" \
    "fixture_preparation_script_sha256\t$(/usr/bin/jq -er '.reviewedSources.fixtureScriptSHA256' "$FIXTURE_MANIFEST")" \
    "fixture_release_notes_sha256\t$(/usr/bin/jq -er '.candidateInputs.releaseNotesSHA256' "$FIXTURE_MANIFEST")" \
    "fixture_public_key_fingerprint_sha256\t$(/usr/bin/jq -er '.tools.publicKeyFingerprintSHA256' "$FIXTURE_MANIFEST")" \
    "feed_fixture_size\t$FIXTURE_FEED_SIZE" \
    "feed_fixture_sha256\t$FIXTURE_FEED_SHA256" \
    "archive_fixture_size\t$FIXTURE_ARCHIVE_SIZE" \
    "archive_fixture_sha256\t$FIXTURE_ARCHIVE_SHA256" \
    "manifest_authenticated_xml_policy\t$FIXTURE_XML_POLICY" \
    "manifest_archive_eddsa\t$FIXTURE_ARCHIVE_EDDSA" \
    >> "$evidence_path"
  if [[ "$CASE_LABEL" == "oversized-signed-feed" ]]; then
    printf 'manifest_feed_verification_mode\tcryptographic-only-2MiB\n' >> "$evidence_path"
  fi
}

require_selected_fixture_bytes_unchanged() {
  [[ "$(release_file_size "$FEED_FIXTURE")" == "$FIXTURE_FEED_SIZE" \
      && "$(release_sha256 "$FEED_FIXTURE")" == "$FIXTURE_FEED_SHA256" \
      && "$(release_file_size "$ARCHIVE_FIXTURE")" == "$FIXTURE_ARCHIVE_SIZE" \
      && "$(release_sha256 "$ARCHIVE_FIXTURE")" == "$FIXTURE_ARCHIVE_SHA256" \
      && "$(release_sha256 "$FIXTURE_MANIFEST")" == "$FIXTURE_MANIFEST_SHA256" \
      && "$(release_sha256 "$FIXTURE_CHECKSUMS")" == "$FIXTURE_CHECKSUMS_SHA256" \
      && "$(release_sha256 "$SCRIPT_DIR/prepare-update-transition-fixtures.sh")" == "$(/usr/bin/jq -er '.reviewedSources.fixtureScriptSHA256' "$FIXTURE_MANIFEST")" \
      && "$(release_sha256 "$SCRIPT_DIR/validate-appcast.sh")" == "$(/usr/bin/jq -er '.reviewedSources.validateAppcastSHA256' "$FIXTURE_MANIFEST")" \
      && "$(release_sha256 "$SCRIPT_DIR/../updates/release-notes/0.1.4.md")" == "$(/usr/bin/jq -er '.candidateInputs.releaseNotesSHA256' "$FIXTURE_MANIFEST")" ]] \
    || release_die "Selected fixture bytes changed after manifest/checksum admission."
}

compile_signature_verifier() {
  local source="$ACTIVE_PHASE_DIRECTORY/FixtureSignatureVerifier.swift"
  local binary="$ACTIVE_PHASE_DIRECTORY/FixtureSignatureVerifier"

  cat > "$source" <<'SWIFT'
import CryptoKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 4 else { exit(EX_USAGE) }
guard
    let publicKeyData = Data(base64Encoded: CommandLine.arguments[1]),
    publicKeyData.count == 32,
    let signature = Data(base64Encoded: CommandLine.arguments[2]),
    signature.count == 64
else { exit(EX_DATAERR) }

do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let message = try Data(
        contentsOf: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: false),
        options: [.mappedIfSafe]
    )
    exit(publicKey.isValidSignature(signature, for: message) ? EX_OK : EX_DATAERR)
} catch {
    exit(EX_IOERR)
}
SWIFT
  chmod 600 "$source"
  /usr/bin/xcrun swiftc -swift-version 5 -O "$source" -o "$binary" \
    || release_die "Could not compile the fixed CryptoKit fixture-signature verifier."
  [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] \
    || release_die "Swift did not produce the fixture-signature verifier."
  /usr/bin/codesign --force --sign - "$binary" >/dev/null 2>&1 \
    || release_die "Could not ad-hoc sign the fixture-signature verifier."
  /usr/bin/codesign --verify --strict "$binary" \
    || release_die "The fixture-signature verifier failed strict code-signature validation."
  printf '%s\n' "$binary"
}

compile_authenticated_xml_validator() {
  local binary="$ACTIVE_PHASE_DIRECTORY/AuthenticatedAppcastValidator"
  local sources="$ACTIVE_PHASE_DIRECTORY/authenticated-validator-sources.sha256"
  local source_path recorded_digest recorded_relative

  : > "$sources"
  for source_path in \
    "$SCRIPT_DIR/../UshotCore/Sources/UshotCore/Product/ProductIdentity.swift" \
    "$SCRIPT_DIR/../UshotCore/Sources/UshotCore/Update/UpdateChecking.swift" \
    "$SCRIPT_DIR/../UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift" \
    "$SCRIPT_DIR/../Tools/AuthenticatedAppcastValidator/main.swift"; do
    [[ -f "$source_path" && ! -L "$source_path" ]] \
      || release_die "Authenticated-appcast validator source is missing or symbolic."
    printf '%s  %s\n' "$(release_sha256 "$source_path")" "${source_path#"$SCRIPT_DIR/../"}" >> "$sources"
  done
  chmod 600 "$sources"
  /usr/bin/xcrun swiftc \
    -parse-as-library -swift-version 5 -O \
    "$SCRIPT_DIR/../UshotCore/Sources/UshotCore/Product/ProductIdentity.swift" \
    "$SCRIPT_DIR/../UshotCore/Sources/UshotCore/Update/UpdateChecking.swift" \
    "$SCRIPT_DIR/../UshotCore/Sources/UshotCore/Update/SignedAppcastPolicy.swift" \
    "$SCRIPT_DIR/../Tools/AuthenticatedAppcastValidator/main.swift" \
    -o "$binary" \
    || release_die "Could not compile the current app-identical authenticated XML validator."
  while read -r recorded_digest recorded_relative; do
    [[ "$recorded_digest" =~ ^[0-9a-f]{64}$ \
        && "$recorded_relative" =~ ^[A-Za-z0-9._/-]+$ \
        && "$(release_sha256 "$SCRIPT_DIR/../$recorded_relative")" == "$recorded_digest" ]] \
      || release_die "Authenticated-appcast validator source changed during compilation."
  done < "$sources"
  /usr/bin/codesign --force --sign - "$binary" >/dev/null 2>&1 \
    || release_die "Could not ad-hoc sign the authenticated-XML validator."
  /usr/bin/codesign --verify --strict "$binary" \
    || release_die "The authenticated-XML validator failed strict code-signature validation."
  printf '%s\n' "$binary"
}

extract_and_verify_signed_feed() {
  local signature_verifier="$1"
  local evidence_path="$2"
  local prefix="$ACTIVE_PHASE_DIRECTORY/authenticated-appcast.xml"
  local signature_file="$ACTIVE_PHASE_DIRECTORY/feed-signature.txt"
  local signature

  /usr/bin/ruby - "$FEED_FIXTURE" "$prefix" "$signature_file" <<'RUBY'
require "base64"
source, prefix_path, signature_path = ARGV
data = File.binread(source)
abort("feed is empty or too large") unless data.bytesize.between?(1, 2_097_152)
pattern = /<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+\/]{86}==)\nlength: ([1-9][0-9]*)\n-->\n?\z/
match = pattern.match(data)
abort("feed has no exact signed-feed trailer") unless match
length = Integer(match[2], 10)
abort("signed length does not meet the trailer boundary") unless length == match.begin(0)
signature = Base64.strict_decode64(match[1]) rescue nil
abort("feed signature is not exactly 64 bytes") unless signature&.bytesize == 64
File.binwrite(prefix_path, data.byteslice(0, length))
File.write(signature_path, match[1] + "\n")
RUBY
  chmod 600 "$prefix" "$signature_file"
  signature="$(/usr/bin/tr -d '\r\n' < "$signature_file")"
  "$signature_verifier" "$USHOT_SPARKLE_PUBLIC_ED_KEY" "$signature" "$prefix" \
    || release_die "Selected fixture feed failed Ed25519 verification with Ushot's embedded public key."
  printf '%b\n' \
    "authenticated_feed_prefix_size\t$(release_file_size "$prefix")" \
    "authenticated_feed_prefix_sha256\t$(release_sha256 "$prefix")" \
    'feed_signature_verified_with_embedded_public_key\tPASS' \
    >> "$evidence_path"
}

verify_authenticated_xml_policy() {
  local validator="$1"
  local evidence_path="$2"
  local stdout_path="$ACTIVE_PHASE_DIRECTORY/authenticated-policy.stdout"
  local stderr_path="$ACTIVE_PHASE_DIRECTORY/authenticated-policy.stderr"
  local expected_stderr="$ACTIVE_PHASE_DIRECTORY/authenticated-policy.expected.stderr"
  local status

  set +e
  "$validator" "$FEED_FIXTURE" > "$stdout_path" 2> "$stderr_path"
  status=$?
  set -e
  chmod 600 "$stdout_path" "$stderr_path"
  if [[ "$FIXTURE_XML_POLICY" == "accepted" ]]; then
    [[ "$status" == "0" && ! -s "$stdout_path" && ! -s "$stderr_path" ]] \
      || release_die "Current app-identical validator did not accept the manifest-accepted authenticated XML."
    printf 'authenticated_xml_policy_observed\tACCEPTED\n' >> "$evidence_path"
  else
    printf 'error: %s: %s\n' \
      "$([[ "$FIXTURE_XML_REJECTION_CATEGORY" == "oversized-signed-feed" ]] && printf 'verified signed appcast envelope violates Ushot policy' || printf 'authenticated appcast violates Ushot runtime policy')" \
      "$FIXTURE_XML_REJECTION_CATEGORY" > "$expected_stderr"
    chmod 600 "$expected_stderr"
    [[ "$status" == "65" && ! -s "$stdout_path" ]] \
      || release_die "Current app-identical validator did not return EX_DATAERR for the rejection-proven fixture."
    /usr/bin/cmp -s "$stderr_path" "$expected_stderr" \
      || release_die "Current app-identical validator returned a different rejection category."
    printf 'authenticated_xml_policy_observed\tREJECTED:%s\n' \
      "$FIXTURE_XML_REJECTION_CATEGORY" >> "$evidence_path"
  fi
  printf '%b\n' \
    "authenticated_validator_sources_sha256\t$(release_sha256 "$ACTIVE_PHASE_DIRECTORY/authenticated-validator-sources.sha256")" \
    "authenticated_validator_binary_sha256\t$(release_sha256 "$validator")" \
    'authenticated_validator_scope\tCURRENT_REPOSITORY_SOURCE_PLUS_INSTALLED_RUNTIME_LOG_EVIDENCE' \
    >> "$evidence_path"
}

verify_feed_archive_binding() {
  local signature_verifier="$1"
  local evidence_path="$2"
  local item_xpath="(/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()=''])[1]"
  local enclosure_xpath="$item_xpath/*[local-name()='enclosure' and namespace-uri()='']"
  local enclosure_url enclosure_length enclosure_signature status
  local expected_url="https://github.com/$USHOT_GITHUB_REPOSITORY/releases/download/v$USHOT_FIRST_FEED_VERSION/$ARCHIVE_NAME"

  [[ "$(/usr/bin/xmllint --xpath "count($enclosure_xpath)" "$ACTIVE_PHASE_DIRECTORY/authenticated-appcast.xml")" == "1" ]] \
    || release_die "Authenticated feed must contain exactly one first-item enclosure."
  enclosure_url="$(/usr/bin/xmllint --xpath "string($enclosure_xpath/@url)" "$ACTIVE_PHASE_DIRECTORY/authenticated-appcast.xml")"
  enclosure_length="$(/usr/bin/xmllint --xpath "string($enclosure_xpath/@length)" "$ACTIVE_PHASE_DIRECTORY/authenticated-appcast.xml")"
  enclosure_signature="$(/usr/bin/xmllint --xpath "string($enclosure_xpath/@*[local-name()='edSignature' and namespace-uri()='$USHOT_SPARKLE_XML_NAMESPACE'])" "$ACTIVE_PHASE_DIRECTORY/authenticated-appcast.xml")"
  [[ "$enclosure_url" == "$expected_url" ]] \
    || release_die "Authenticated feed enclosure URL is not the exact official 0.1.4 asset URL."
  [[ "$enclosure_length" =~ ^[1-9][0-9]*$ \
      && "$enclosure_length" == "$FIXTURE_ARCHIVE_SIZE" ]] \
    || release_die "Authenticated feed enclosure length does not equal the selected archive bytes."
  [[ "$enclosure_signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
    || release_die "Authenticated feed enclosure signature is malformed."

  set +e
  "$signature_verifier" \
    "$USHOT_SPARKLE_PUBLIC_ED_KEY" \
    "$enclosure_signature" \
    "$ARCHIVE_FIXTURE"
  status=$?
  set -e
  if [[ "$FIXTURE_ARCHIVE_EDDSA" == "verified" ]]; then
    [[ "$status" == "0" ]] \
      || release_die "Manifest-verified archive failed independent Ed25519 verification."
    printf 'archive_signature_verified_with_embedded_public_key\tPASS\n' >> "$evidence_path"
  else
    [[ "$status" == "65" ]] \
      || release_die "Tampered archive did not fail independent Ed25519 verification with EX_DATAERR."
    printf 'archive_signature_rejection_verified_with_embedded_public_key\tPASS\n' >> "$evidence_path"
  fi
  printf '%b\n' \
    "authenticated_enclosure_url\t$enclosure_url" \
    "authenticated_enclosure_length\t$enclosure_length" \
    "authenticated_enclosure_signature_sha256\t$(printf '%s' "$enclosure_signature" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" \
    'feed_archive_url_length_signature_binding\tPASS' \
    >> "$evidence_path"
}

verify_fixture_authenticity_and_policy() {
  local evidence_path="$1"
  local signature_verifier validator

  signature_verifier="$(compile_signature_verifier)"
  validator="$(compile_authenticated_xml_validator)"
  extract_and_verify_signed_feed "$signature_verifier" "$evidence_path"
  verify_authenticated_xml_policy "$validator" "$evidence_path"
  verify_feed_archive_binding "$signature_verifier" "$evidence_path"
  require_selected_fixture_bytes_unchanged
  printf '%b\n' \
    "signature_verifier_source_sha256\t$(release_sha256 "$ACTIVE_PHASE_DIRECTORY/FixtureSignatureVerifier.swift")" \
    "signature_verifier_binary_sha256\t$(release_sha256 "$signature_verifier")" \
    >> "$evidence_path"
}

write_zip_preflight() {
  local source="$1"

  cat > "$source" <<'RUBY'
require "base64"
require "zlib"

archive, output = ARGV
data = File.binread(archive)
abort("archive size is outside verifier bounds") unless data.bytesize.between?(1, 134_217_728)
minimum = [0, data.bytesize - 65_557].max
eocd_offset = data.rindex("PK\x05\x06".b)
abort("missing end of central directory") unless eocd_offset && eocd_offset >= minimum
eocd = data.byteslice(eocd_offset, 22)&.unpack("VvvvvVVv")
abort("truncated end of central directory") unless eocd
_, disk, central_disk, disk_entries, total_entries, central_size, central_offset, comment_length = eocd
abort("multi-disk or ZIP64 archive is forbidden") unless disk.zero? && central_disk.zero? && disk_entries == total_entries && total_entries < 65_535 && central_size < 0xffff_ffff && central_offset < 0xffff_ffff
abort("archive comment or trailing bytes are malformed") unless eocd_offset + 22 + comment_length == data.bytesize
abort("central directory boundary is inconsistent") unless central_offset + central_size == eocd_offset

entries = []
seen = {}
position = central_offset
total_uncompressed = 0
total_entries.times do
  fields = data.byteslice(position, 46)&.unpack("VvvvvvvVVVvvvvvVV")
  abort("truncated central directory entry") unless fields && fields[0] == 0x02014b50
  _, made_by, _, flags, method, _, _, crc, compressed_size, uncompressed_size,
    name_length, extra_length, entry_comment_length, start_disk, _, external_attributes, local_offset = fields
  name_bytes = data.byteslice(position + 46, name_length)
  abort("truncated central directory name") unless name_bytes&.bytesize == name_length
  abort("non-Unix ZIP entry is forbidden") unless (made_by >> 8) == 3
  abort("encrypted or unsupported ZIP flags are forbidden") unless (flags & ~(0x0008 | 0x0800)).zero?
  abort("unsupported ZIP compression method") unless [0, 8].include?(method)
  abort("multi-disk ZIP entry is forbidden") unless start_disk.zero?
  abort("ZIP entry name must be printable ASCII") unless name_bytes.bytes.all? { |byte| byte.between?(0x20, 0x7e) }
  name = name_bytes.dup.force_encoding(Encoding::UTF_8)
  abort("unsafe ZIP entry path") if name.empty? || name.start_with?("/") || name.include?("\\") || name.include?("//")
  components = name.delete_suffix("/").split("/", -1)
  abort("dot or empty ZIP path component") if components.empty? || components.any? { |component| component.empty? || component == "." || component == ".." }
  abort("entry outside Ushot.app allowlist") unless components.first == "Ushot.app" || components.first == "__MACOSX"
  abort("duplicate ZIP path") if seen.key?(name)
  seen[name] = true

  unix_mode = (external_attributes >> 16) & 0xffff
  type_bits = unix_mode & 0o170000
  kind = case type_bits
         when 0o040000 then "D"
         when 0o100000 then "F"
         when 0o120000 then "L"
         else abort("special or untyped ZIP filesystem object is forbidden")
         end
  abort("directory slash/type mismatch") unless (kind == "D") == name.end_with?("/")
  abort("directory entry carries data") if kind == "D" && (!compressed_size.zero? || !uncompressed_size.zero?)

  local = data.byteslice(local_offset, 30)&.unpack("VvvvvvVVVvv")
  abort("truncated local header") unless local && local[0] == 0x04034b50
  local_flags, local_method, local_name_length, local_extra_length = local[2], local[3], local[9], local[10]
  abort("central/local flags or compression differ") unless local_flags == flags && local_method == method
  local_name = data.byteslice(local_offset + 30, local_name_length)
  abort("central/local names differ") unless local_name == name_bytes
  content_offset = local_offset + 30 + local_name_length + local_extra_length
  abort("entry data overlaps central directory") unless content_offset >= 0 && content_offset + compressed_size <= central_offset
  compressed = data.byteslice(content_offset, compressed_size)
  content = if method.zero?
              compressed
            else
              inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
              begin
                value = inflater.inflate(compressed) + inflater.finish
              ensure
                inflater.close
              end
              value
            end
  abort("entry size mismatch") unless content.bytesize == uncompressed_size
  abort("entry CRC mismatch") unless Zlib.crc32(content) == crc
  total_uncompressed += uncompressed_size
  abort("expanded archive exceeds 512 MiB") if total_uncompressed > 536_870_912
  if kind == "L"
    abort("metadata symlink is forbidden") unless components.first == "Ushot.app"
    abort("symlink target must be printable ASCII") unless content.bytes.all? { |byte| byte.between?(0x20, 0x7e) }
    target = content.dup.force_encoding(Encoding::UTF_8)
    abort("unsafe symlink target") if target.empty? || target.start_with?("/") || target.include?("\\") || target.include?("//")
    target_components = target.split("/", -1)
    abort("dot/parent/empty symlink target component") if target_components.any? { |component| component.empty? || component == "." || component == ".." }
  end
  entries << [kind, Base64.strict_encode64(name), format("%o", unix_mode & 0o7777), uncompressed_size, format("%08x", crc)]
  position += 46 + name_length + extra_length + entry_comment_length
end
abort("central directory entry count/size mismatch") unless position == central_offset + central_size

symlink_paths = entries.select { |entry| entry[0] == "L" }.map { |entry| Base64.strict_decode64(entry[1]).delete_suffix("/") }
all_paths = entries.map { |entry| Base64.strict_decode64(entry[1]).delete_suffix("/") }
symlink_paths.each do |symlink|
  abort("archive writes through a symlink path") if all_paths.any? { |path| path.start_with?(symlink + "/") }
end

File.open(output, "wb", 0o600) do |file|
  entries.sort_by { |entry| entry[1] }.each { |entry| file.puts(entry.join("\t")) }
end
RUBY
  chmod 600 "$source"
}

safe_extract_archive() {
  local archive_path="$1"
  local expected_version="$2"
  local expected_build="$3"
  local evidence_path="$4"
  local label="${5:-archive}"
  local source_kind="${6:-fixture}"
  local preflight="$ACTIVE_PHASE_DIRECTORY/$label-zip-preflight.rb"
  local entries="$ACTIVE_PHASE_DIRECTORY/$label-validated-entries.tsv"
  local extraction_root="$ACTIVE_PHASE_DIRECTORY/$label-extracted"
  local extracted_app="$extraction_root/$USHOT_APP_BUNDLE"
  local sandbox_profile="$ACTIVE_PHASE_DIRECTORY/$label-extraction.sb"
  local manifest="$ACTIVE_PHASE_DIRECTORY/$label-bundle-manifest.tsv"
  local xattrs="$ACTIVE_PHASE_DIRECTORY/$label-xattrs.tsv"
  local codesign_stderr="$ACTIVE_PHASE_DIRECTORY/$label-codesign.stderr"
  local link real

  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ \
      && ( "$source_kind" == "fixture" || "$source_kind" == "published-baseline" ) ]] \
    || release_die "Archive extraction label/source kind is invalid."
  write_zip_preflight "$preflight"
  /usr/bin/ruby "$preflight" "$archive_path" "$entries" \
    || release_die "Archive central-directory/type/symlink preflight rejected the selected ZIP before extraction."
  chmod 600 "$entries"
  mkdir -m 700 "$extraction_root"
  cat > "$sandbox_profile" <<'SANDBOX'
(version 1)
(allow default)
(deny file-write* (require-not (subpath (param "EXTRACTION_ROOT"))))
SANDBOX
  chmod 600 "$sandbox_profile"
  /usr/bin/sandbox-exec \
    -D "EXTRACTION_ROOT=$extraction_root" \
    -f "$sandbox_profile" \
    /usr/bin/ditto -x -k \
      --norsrc --noextattr --noqtn --noacl --nopersistRootless \
      "$archive_path" "$extraction_root" \
    || release_die "Sandbox-confined metadata-minimized archive extraction failed."
  [[ -d "$extracted_app" && ! -L "$extracted_app" ]] \
    || release_die "Archive did not extract one real $USHOT_APP_BUNDLE."
  while IFS= read -r -d '' link; do
    real="$(/usr/bin/ruby -e 'puts File.realpath(ARGV.fetch(0))' "$link")" \
      || release_die "Extracted bundle contains an unresolved symlink."
    [[ "$real" == "$extracted_app" || "$real" == "$extracted_app/"* ]] \
      || release_die "Extracted bundle contains a symlink resolving outside Ushot.app."
  done < <(/usr/bin/find "$extracted_app" -type l -print0)
  release_validate_app_identity "$extracted_app" "$expected_version" "$expected_build"
  release_verify_signature_mode "$extracted_app" public-adhoc
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$extracted_app" \
    > /dev/null 2> "$codesign_stderr" \
    || release_die "Safely extracted Ushot failed final strict deep code-signature validation."
  chmod 600 "$codesign_stderr"
  write_bundle_manifest "$extracted_app" "$manifest"
  record_bundle_xattrs "$extracted_app" "$xattrs" provenance-only "$evidence_path" "$label"
  if [[ "$source_kind" == "fixture" ]]; then
    require_selected_fixture_bytes_unchanged
  else
    [[ "$(release_file_size "$archive_path")" == "$BASELINE_ZIP_SIZE" \
        && "$(release_sha256 "$archive_path")" == "$BASELINE_ZIP_SHA256" ]] \
      || release_die "Pinned public baseline ZIP changed during safe extraction."
  fi
  printf '%b\n' \
    "$label.archive_preflight_scope\tCENTRAL_LOCAL_HEADERS_TYPES_PATHS_CRC_SYMLINK_WRITE_PREFIX_BEFORE_EXTRACTION" \
    "$label.archive_extraction_write_scope\tSANDBOX_FRESH_PHASE_ROOT_ONLY" \
    "$label.archive_extraction_metadata\tSOURCE_EXTATTR_RESOURCE_FORK_QUARANTINE_ACL_ROOTLESS_STRIPPED_OS_PROVENANCE_ONLY_ALLOWED" \
    "$label.archive_final_codesign\tPASS" \
    "$label.archive_bundle_manifest_sha256\t$(release_sha256 "$manifest")" \
    >> "$evidence_path"
}

record_plist_entry() {
  local prefix="$1" plist_path="$2" key="$3" evidence_path="$4"
  local value_type value
  value_type="$(/usr/bin/plutil -type "$key" "$plist_path" 2>/dev/null)" \
    || release_die "Missing $key in the inspected $prefix Info.plist."
  value="$(release_plist_value "$plist_path" "$key")"
  printf '%s.%s.type\t%s\n%s.%s.value\t%s\n' \
    "$prefix" "$key" "$value_type" "$prefix" "$key" "$value" >> "$evidence_path"
}

record_app_policy() {
  local app_path="$1" evidence_path="$2"
  local info_plist="$app_path/Contents/Info.plist"
  local framework_info="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
  local key
  for key in CFBundleIdentifier CFBundleName CFBundleExecutable CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey SURequireSignedFeed SURequireExactUpdateVersionIdentity SURequireEdDSAUpdateArchiveSignature SURequireHostSignedAppcastValidation SUMaximumSignedAppcastContentLength SUSignedFeedFailureExpirationInterval SUVerifyUpdateBeforeExtraction SUEnableAutomaticChecks SUAutomaticallyUpdate SUAllowsAutomaticUpdates SUEnableSystemProfiling; do
    record_plist_entry host "$info_plist" "$key" "$evidence_path"
  done
  for key in CFBundleShortVersionString CFBundleVersion SUUpdateVersionIdentityHardeningVersion SUHostSignedAppcastValidationVersion SUFeedDownloadSizeLimitVersion; do
    record_plist_entry framework "$framework_info" "$key" "$evidence_path"
  done
}

parse_lsof_text_identity() {
  local input_path="$1" expected_executable="$2" expected_pid="$3" output_path="$4"

  /usr/bin/ruby - "$input_path" "$expected_executable" "$expected_pid" "$output_path" <<'RUBY' || return 1
input_path, expected_executable, expected_pid_text, output_path = ARGV
expected_pid = Integer(expected_pid_text, 10)
abort("invalid expected PID") unless expected_pid.positive?
bytes = File.binread(input_path)
abort("lsof output contains NUL or carriage return") if bytes.include?("\0") || bytes.include?("\r")
lines = bytes.lines(chomp: true)
abort("lsof output is empty") if lines.empty?

process_ids = []
records = []
current = nil
finish_record = lambda do
  next unless current
  records << current
  current = nil
end

lines.each do |line|
  abort("empty lsof field") if line.empty?
  identifier = line.getbyte(0)&.chr
  value = line.byteslice(1..)
  case identifier
  when "p"
    finish_record.call
    abort("malformed lsof PID") unless value&.match?(/\A[1-9][0-9]*\z/)
    process_ids << Integer(value, 10)
  when "f"
    abort("lsof file record precedes PID") if process_ids.empty?
    finish_record.call
    abort("empty lsof descriptor") if value.nil? || value.empty?
    current = { "f" => value }
  when "D", "i", "n"
    abort("lsof field precedes file descriptor") unless current
    abort("duplicate lsof field") if current.key?(identifier)
    abort("empty lsof field value") if value.nil? || value.empty?
    current[identifier] = value
  else
    abort("unexpected lsof field identifier")
  end
end
finish_record.call

abort("lsof PID record is not unique or does not match") \
  unless process_ids == [expected_pid]
abort("lsof returned a non-txt record") \
  unless !records.empty? && records.all? { |record| record.fetch("f") == "txt" }
abort("an lsof txt record is incomplete") \
  unless records.all? { |record| record.keys.sort == %w[D f i n] }
matches = records.select { |record| record.fetch("n") == expected_executable }
abort("lsof did not return exactly one txt record for the expected executable") \
  unless matches.length == 1
record = matches.fetch(0)
path = record.fetch("n")
raw_device = record.fetch("D")
abort("malformed lsof device") unless raw_device.match?(/\A(?:0x[0-9A-Fa-f]+|[0-9]+)\z/)
device = raw_device.start_with?("0x") ? Integer(raw_device.delete_prefix("0x"), 16) : Integer(raw_device, 10)
inode_text = record.fetch("i")
abort("malformed lsof inode") unless inode_text.match?(/\A[1-9][0-9]*\z/)
inode = Integer(inode_text, 10)

File.open(output_path, "wb", 0o600) do |file|
  file.puts("path\t#{path}")
  file.puts("device\t#{device}")
  file.puts("inode\t#{inode}")
  file.puts("raw_device\t#{raw_device}")
end
RUBY
  [[ -f "$output_path" && ! -L "$output_path" ]] || return 1
  chmod 600 "$output_path"
}

compile_process_identity_sampler() {
  local source="$ACTIVE_PHASE_DIRECTORY/process-identity-sampler.c"
  local binary="$ACTIVE_PHASE_DIRECTORY/process-identity-sampler"

  cat > "$source" <<'C_SOURCE'
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sysexits.h>
#include <sys/proc_info.h>
#include <sys/types.h>

int main(int argc, char **argv) {
    char *end = NULL;
    long parsed_pid;
    struct proc_bsdinfo info;
    int size;

    if (argc != 2) {
        return EX_USAGE;
    }
    errno = 0;
    parsed_pid = strtol(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' || parsed_pid <= 0 || parsed_pid > INT32_MAX) {
        return EX_USAGE;
    }
    size = proc_pidinfo((int)parsed_pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));
    if (size != (int)sizeof(info)) {
        return EX_UNAVAILABLE;
    }
    if (info.pbi_pid != (uint32_t)parsed_pid || info.pbi_start_tvusec >= 1000000) {
        return EX_DATAERR;
    }
    if (printf("pid\t%u\nruid\t%u\neuid\t%u\nstart_sec\t%" PRIu64 "\nstart_usec\t%" PRIu64 "\n",
               info.pbi_pid,
               (unsigned int)info.pbi_ruid,
               (unsigned int)info.pbi_uid,
               info.pbi_start_tvsec,
               info.pbi_start_tvusec) < 0) {
        return EX_IOERR;
    }
    return EX_OK;
}
C_SOURCE
  chmod 600 "$source"
  /usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -Werror "$source" -o "$binary" \
    || release_die "Could not compile the fixed libproc process-identity sampler."
  [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] \
    || release_die "Clang did not produce the process-identity sampler."
  /usr/bin/codesign --force --sign - "$binary" >/dev/null 2>&1 \
    || release_die "Could not ad-hoc sign the process-identity sampler."
  /usr/bin/codesign --verify --strict "$binary" \
    || release_die "The process-identity sampler failed strict code-signature validation."
  printf '%s\n' "$binary"
}

sample_process_identity() {
  local sampler="$1" pid="$2" output_path="$3"
  local expected_keys="$ACTIVE_PHASE_DIRECTORY/process-identity-expected-keys.txt"
  local actual_keys="$ACTIVE_PHASE_DIRECTORY/process-identity-actual-keys.txt"

  "$sampler" "$pid" > "$output_path" \
    || release_die "Could not sample the Ushot process through proc_pidinfo."
  chmod 600 "$output_path"
  printf '%s\n' pid ruid euid start_sec start_usec > "$expected_keys"
  /usr/bin/awk -F '\t' 'NF == 2 { print $1 }' "$output_path" > "$actual_keys"
  /usr/bin/cmp -s "$expected_keys" "$actual_keys" \
    || release_die "The proc_pidinfo sampler returned a malformed identity record."
  [[ "$(evidence_value_from_file "$output_path" pid)" == "$pid" \
      && "$(evidence_value_from_file "$output_path" ruid)" =~ ^[0-9]+$ \
      && "$(evidence_value_from_file "$output_path" euid)" =~ ^[0-9]+$ \
      && "$(evidence_value_from_file "$output_path" start_sec)" =~ ^[1-9][0-9]*$ \
      && "$(evidence_value_from_file "$output_path" start_usec)" =~ ^[0-9]{1,6}$ ]] \
    || release_die "The proc_pidinfo sampler returned malformed process values."
  chmod 600 "$expected_keys" "$actual_keys"
}

process_identity_samples_match() {
  local left="$1" right="$2" key
  for key in pid ruid euid start_sec start_usec; do
    [[ "$(evidence_value_from_file "$left" "$key")" == "$(evidence_value_from_file "$right" "$key")" ]] \
      || return 1
  done
}

success_pid_transition_is_distinct() {
  local old_pid="$1" new_pid="$2"
  [[ "$old_pid" =~ ^[1-9][0-9]*$ \
      && "$new_pid" =~ ^[1-9][0-9]*$ \
      && "$new_pid" != "$old_pid" ]]
}

record_running_app() {
  local app_path="$1" evidence_path="$2"
  local expected_executable="$app_path/Contents/MacOS/$USHOT_EXECUTABLE_NAME"
  local pids_before="$ACTIVE_PHASE_DIRECTORY/ushot-pids-before.txt"
  local pids_after="$ACTIVE_PHASE_DIRECTORY/ushot-pids-after.txt"
  local sample_before="$ACTIVE_PHASE_DIRECTORY/process-identity-before.tsv"
  local sample_after="$ACTIVE_PHASE_DIRECTORY/process-identity-after.tsv"
  local lsof_raw="$ACTIVE_PHASE_DIRECTORY/running-executable-lsof.raw"
  local lsof_parsed="$ACTIVE_PHASE_DIRECTORY/running-executable-lsof.tsv"
  local sampler pid_count pid executable_sha_before executable_sha_after
  local stat_before stat_after executable_device executable_inode executable_ctime
  local lsof_device lsof_inode real_uid effective_uid start_epoch start_usec start_text
  local boot_uuid_before boot_uuid_after status sampler_sha_before sampler_sha_after

  if /usr/bin/pgrep -u "$CURRENT_UID" -x "$USHOT_EXECUTABLE_NAME" > "$pids_before"; then :; else
    [[ $? -eq 1 ]] || release_die "Could not enumerate current-effective-UID Ushot processes."
  fi
  pid_count="$(/usr/bin/awk 'NF {n+=1} END {print n+0}' "$pids_before")"
  [[ "$pid_count" == "1" ]] || release_die "Expected exactly one current-user Ushot process; found $pid_count."
  pid="$(/usr/bin/awk 'NF {print; exit}' "$pids_before")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || release_die "Ushot process enumeration returned a malformed PID."
  [[ -f "$expected_executable" && ! -L "$expected_executable" ]] \
    || release_die "Installed Ushot executable is not a regular non-symbolic file."

  sampler="$(compile_process_identity_sampler)"
  sampler_sha_before="$(release_sha256 "$sampler")"
  sample_process_identity "$sampler" "$pid" "$sample_before"
  boot_uuid_before="$(/usr/sbin/sysctl -n kern.bootsessionuuid)" \
    || release_die "Could not record the current macOS boot-session UUID."
  stat_before="$(/usr/bin/stat -f '%d %i %c' "$expected_executable")" \
    || release_die "Could not stat the installed executable before process-vnode sampling."
  executable_sha_before="$(release_sha256 "$expected_executable")"

  set +e
  /usr/sbin/lsof -a -p "$pid" -F fDin -d txt > "$lsof_raw" 2>/dev/null
  status=$?
  set -e
  chmod 600 "$lsof_raw"
  [[ "$status" == "0" ]] \
    || release_die "lsof could not return the selected Ushot process text vnode."
  parse_lsof_text_identity "$lsof_raw" "$expected_executable" "$pid" "$lsof_parsed" \
    || release_die "The selected Ushot process does not expose one exact installed-executable txt vnode."

  sample_process_identity "$sampler" "$pid" "$sample_after"
  boot_uuid_after="$(/usr/sbin/sysctl -n kern.bootsessionuuid)" \
    || release_die "Could not re-sample the current macOS boot-session UUID."
  executable_sha_after="$(release_sha256 "$expected_executable")"
  stat_after="$(/usr/bin/stat -f '%d %i %c' "$expected_executable")" \
    || release_die "Could not stat the installed executable after process-vnode sampling."
  if /usr/bin/pgrep -u "$CURRENT_UID" -x "$USHOT_EXECUTABLE_NAME" > "$pids_after"; then :; else
    [[ $? -eq 1 ]] || release_die "Could not re-enumerate current-effective-UID Ushot processes."
  fi
  sampler_sha_after="$(release_sha256 "$sampler")"
  [[ "$sampler_sha_before" == "$sampler_sha_after" ]] \
    || release_die "The process-identity sampler changed while it was executing."
  process_identity_samples_match "$sample_before" "$sample_after" \
    || release_die "Ushot PID/real UID/effective UID/microsecond start identity changed during sampling."
  /usr/bin/cmp -s "$pids_before" "$pids_after" \
    || release_die "The exact current-user Ushot process set changed during sampling."
  [[ "$boot_uuid_before" == "$boot_uuid_after" \
      && "$boot_uuid_before" =~ ^[0-9A-Fa-f-]{36}$ ]] \
    || release_die "The macOS boot-session identity changed or was malformed during process sampling."
  [[ "$stat_before" == "$stat_after" \
      && "$executable_sha_before" == "$executable_sha_after" ]] \
    || release_die "The installed executable vnode/ctime/hash changed during process sampling."

  read -r executable_device executable_inode executable_ctime <<< "$stat_before"
  [[ "$executable_device" =~ ^[0-9]+$ \
      && "$executable_inode" =~ ^[1-9][0-9]*$ \
      && "$executable_ctime" =~ ^[0-9]+$ ]] \
    || release_die "Installed executable stat identity is malformed."
  lsof_device="$(evidence_value_from_file "$lsof_parsed" device)"
  lsof_inode="$(evidence_value_from_file "$lsof_parsed" inode)"
  [[ "$lsof_device" == "$executable_device" && "$lsof_inode" == "$executable_inode" ]] \
    || release_die "Running Ushot txt vnode does not match the st_dev/st_ino of the installed executable."
  real_uid="$(evidence_value_from_file "$sample_before" ruid)"
  effective_uid="$(evidence_value_from_file "$sample_before" euid)"
  [[ "$real_uid" == "$CURRENT_UID" && "$effective_uid" == "$CURRENT_UID" ]] \
    || release_die "Running Ushot real/effective UID does not match the verifier user."
  start_epoch="$(evidence_value_from_file "$sample_before" start_sec)"
  start_usec="$(evidence_value_from_file "$sample_before" start_usec)"
  start_text="$(LC_ALL=C /bin/date -r "$start_epoch" '+%a %b %e %T %Y')" \
    || release_die "Could not format the proc_pidinfo process start time."

  printf '%b\n' \
    "running_pid\t$pid" \
    "running_real_uid\t$real_uid" \
    "running_effective_uid\t$effective_uid" \
    "running_boot_session_uuid\t$boot_uuid_before" \
    "running_executable_path\t$expected_executable" \
    "running_executable_sha256\t$executable_sha_before" \
    "running_executable_device\t$executable_device" \
    "running_executable_inode\t$executable_inode" \
    "running_executable_ctime_epoch\t$executable_ctime" \
    "running_lsof_txt_device\t$lsof_device" \
    "running_lsof_txt_inode\t$lsof_inode" \
    "running_process_start_text\t$start_text" \
    "running_process_start_epoch\t$start_epoch" \
    "running_process_start_microseconds\t$start_usec" \
    "process_identity_sampler_source_sha256\t$(release_sha256 "$ACTIVE_PHASE_DIRECTORY/process-identity-sampler.c")" \
    "process_identity_sampler_binary_sha256\t$sampler_sha_before" \
    'running_process_start_resolution\tLIBPROC_PROC_PIDTBSDINFO_MICROSECOND_BOUND_TO_BOOT_UUID_AND_EXECUTABLE_VNODE_SHA256' \
    'process_identity_stable_sampling\tTWO_IDENTICAL_LIBPROC_SAMPLES_BRACKETING_LSOF_AND_EXECUTABLE_STAT_HASH' \
    'running_executable_vnode_matches_installed_executable\tPASS' \
    'process_enumeration_scope\tTWO_IDENTICAL_CURRENT_EFFECTIVE_UID_PROCESS_SETS_WITH_LIBPROC_REAL_UID_CONFIRMATION' \
    >> "$evidence_path"
  chmod 600 "$pids_before" "$pids_after"
}

record_helper_snapshot() {
  local evidence_path="$1"
  local output="$ACTIVE_PHASE_DIRECTORY/sparkle-helper-processes.tsv"
  local framework_root="$INSTALLED_APP/Contents/Frameworks/Sparkle.framework"
  local helper pid pids uid ruid ppid classification expected_path expected_count
  local raw parsed parser_stderr lsof_status parser_status installed_path_count
  local stat_before stat_after expected_device expected_inode expected_ctime
  local observed_device observed_inode
  local total=0 privileged=0 attributed=0 exited=0

  : > "$output"
  for helper in Autoupdate Updater Downloader Installer InstallerLauncher; do
    expected_path=""
    expected_count="$(/usr/bin/find "$framework_root" -type f -name "$helper" -print \
      | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "$expected_count" -le 1 ]] \
      || release_die "Installed Sparkle tree contains multiple executable candidates for $helper."
    if [[ "$expected_count" == "1" ]]; then
      expected_path="$(/usr/bin/find "$framework_root" -type f -name "$helper" -print)"
      [[ "$expected_path" == "$framework_root/"* \
          && -f "$expected_path" && ! -L "$expected_path" ]] \
        || release_die "Installed Sparkle helper candidate is not an exact regular path in the installed tree."
    fi
    pids="$ACTIVE_PHASE_DIRECTORY/helper-$helper-pids.txt"
    if /usr/bin/pgrep -x "$helper" > "$pids"; then :; else
      [[ $? -eq 1 ]] || release_die "Could not enumerate all-UID $helper processes."
    fi
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
      uid="$(ps -p "$pid" -o uid= | /usr/bin/tr -d '[:space:]')"
      ruid="$(ps -p "$pid" -o ruid= | /usr/bin/tr -d '[:space:]')"
      ppid="$(ps -p "$pid" -o ppid= | /usr/bin/tr -d '[:space:]')"
      [[ "$uid" =~ ^[0-9]+$ && "$ruid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] \
        || release_die "A Sparkle helper name match changed or returned malformed process ownership."
      raw="$ACTIVE_PHASE_DIRECTORY/helper-$helper-$pid-lsof.raw"
      parsed="$ACTIVE_PHASE_DIRECTORY/helper-$helper-$pid-lsof.tsv"
      parser_stderr="$ACTIVE_PHASE_DIRECTORY/helper-$helper-$pid-lsof-parser.stderr"
      set +e
      /usr/sbin/lsof -a -p "$pid" -F fDin -d txt > "$raw" 2> "$parser_stderr"
      lsof_status=$?
      set -e
      chmod 600 "$raw" "$parser_stderr"
      classification="NAME_MATCH_OUTSIDE_INSTALLED_TREE"
      observed_device="-"
      observed_inode="-"
      if [[ "$lsof_status" == "0" ]]; then
        parser_status=1
        if [[ -n "$expected_path" ]]; then
          stat_before="$(/usr/bin/stat -f '%d %i %c' "$expected_path")" \
            || release_die "Could not stat the exact installed Sparkle helper candidate."
          set +e
          parse_lsof_text_identity "$raw" "$expected_path" "$pid" "$parsed" 2>> "$parser_stderr"
          parser_status=$?
          set -e
          if [[ "$parser_status" == "0" ]]; then
            stat_after="$(/usr/bin/stat -f '%d %i %c' "$expected_path")" \
              || release_die "Could not re-stat the exact installed Sparkle helper candidate."
            [[ "$stat_before" == "$stat_after" ]] \
              || release_die "Installed Sparkle helper vnode changed during lsof attribution."
            read -r expected_device expected_inode expected_ctime <<< "$stat_before"
            observed_device="$(evidence_value_from_file "$parsed" device)"
            observed_inode="$(evidence_value_from_file "$parsed" inode)"
            [[ "$expected_device" =~ ^[0-9]+$ \
                && "$expected_inode" =~ ^[1-9][0-9]*$ \
                && "$expected_ctime" =~ ^[0-9]+$ \
                && "$observed_device" == "$expected_device" \
                && "$observed_inode" == "$expected_inode" ]] \
              || release_die "Sparkle helper txt vnode does not match the exact installed-tree executable stat."
            classification="USHOT_INSTALLED_TREE_EXACT_PATH_AND_VNODE"
            attributed=$((attributed + 1))
          fi
        fi
        if [[ "$parser_status" != "0" ]]; then
          installed_path_count="$(/usr/bin/awk -v prefix="n$framework_root/" \
            'index($0, prefix) == 1 { count += 1 } END { print count + 0 }' "$raw")"
          [[ "$installed_path_count" == "0" ]] \
            || release_die "A Sparkle helper txt vnode points into the installed tree without matching its exact allowed executable path/stat."
        fi
      else
        if ps -p "$pid" >/dev/null 2>&1; then
          release_die "Could not inspect a still-running Sparkle helper name match with lsof."
        fi
        classification="EXITED_DURING_SNAPSHOT"
        exited=$((exited + 1))
      fi
      [[ "$uid" == "0" || "$ruid" == "0" ]] && privileged=$((privileged + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$helper" "$pid" "$ppid" "$ruid" "$uid" "$classification" \
        "$(base64_text "${expected_path:--}")" "$observed_device" "$observed_inode" >> "$output"
      total=$((total + 1))
    done < "$pids"
    chmod 600 "$pids"
  done
  chmod 600 "$output"
  printf '%b\n' \
    'sparkle_helper_snapshot_scope\tALL_VISIBLE_REAL_AND_EFFECTIVE_UIDS_EXACT_PROCESS_NAMES' \
    "sparkle_helper_name_match_count\t$total" \
    "sparkle_helper_privileged_name_match_count\t$privileged" \
    "sparkle_helper_installed_ushot_path_count\t$attributed" \
    "sparkle_helper_exited_during_snapshot_count\t$exited" \
    'sparkle_helper_attribution_contract\tEXACT_AUTHENTICATED_INSTALLED_TREE_PATH_PLUS_STABLE_STAT_DEV_INODE_MATCHING_UNIQUE_LSOF_TXT_RECORD' \
    'sparkle_helper_claim_boundary\tNAME_MATCHES_OUTSIDE_INSTALLED_USHOT_TREE_ARE_RECORDED_NOT_ATTRIBUTED' \
    >> "$evidence_path"
  [[ "$attributed" == "0" ]] \
    || release_die "A helper executing from the installed Ushot Sparkle framework remains active."
}

record_runtime_image_identities() {
  local app_path="$1" evidence_path="$2"
  local output="$ACTIVE_PHASE_DIRECTORY/runtime-image-identities.tsv"
  local uuid_output="$ACTIVE_PHASE_DIRECTORY/runtime-image-uuid.txt"
  local allowlist="$ACTIVE_PHASE_DIRECTORY/runtime-image-uuid-allowlist.txt"
  local host_allowlist="$ACTIVE_PHASE_DIRECTORY/host-executable-uuid-allowlist.txt"
  local relative path marker uuid architecture extra image_uuid_count
  local image_count=0 uuid_count=0
  local -a relative_paths=(
    "Contents/MacOS/$USHOT_EXECUTABLE_NAME"
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  )

  : > "$output"
  : > "$allowlist"
  : > "$host_allowlist"
  for relative in "${relative_paths[@]}"; do
    path="$app_path/$relative"
    [[ -f "$path" && ! -L "$path" ]] \
      || release_die "A required Ushot/Sparkle runtime image is missing or symbolic: $relative"
    /usr/bin/xcrun dwarfdump --uuid "$path" > "$uuid_output" \
      || release_die "Could not derive a Mach-O UUID for runtime image: $relative"
    image_uuid_count=0
    while IFS=' ' read -r marker uuid architecture extra; do
      [[ "$marker" == "UUID:" \
          && "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ \
          && "$architecture" =~ ^[(][A-Za-z0-9_]+[)]$ ]] \
        || release_die "Runtime image returned a malformed Mach-O UUID row: $relative"
      uuid="$(printf '%s' "$uuid" | /usr/bin/tr '[:lower:]' '[:upper:]')"
      architecture="${architecture#(}"
      architecture="${architecture%)}"
      printf '%s\t%s\t%s\t%s\n' \
        "$uuid" "$(release_sha256 "$path")" "$(base64_text "$relative")" "$architecture" >> "$output"
      printf '%s\n' "$uuid" >> "$allowlist"
      if [[ "$relative" == "Contents/MacOS/$USHOT_EXECUTABLE_NAME" ]]; then
        printf '%s\n' "$uuid" >> "$host_allowlist"
      fi
      image_uuid_count=$((image_uuid_count + 1))
      uuid_count=$((uuid_count + 1))
    done < "$uuid_output"
    [[ "$image_uuid_count" -ge 1 ]] \
      || release_die "Runtime image exposes no Mach-O UUID: $relative"
    image_count=$((image_count + 1))
  done
  LC_ALL=C /usr/bin/sort -o "$output" "$output"
  LC_ALL=C /usr/bin/sort -u -o "$allowlist" "$allowlist"
  LC_ALL=C /usr/bin/sort -u -o "$host_allowlist" "$host_allowlist"
  [[ "$image_count" == "6" \
      && "$uuid_count" -ge 6 \
      && "$(/usr/bin/awk 'NF { count += 1 } END { print count + 0 }' "$host_allowlist")" -ge 1 \
      && "$(/usr/bin/awk 'NF { count += 1 } END { print count + 0 }' "$allowlist")" == "$uuid_count" ]] \
    || release_die "Runtime image UUID identities are incomplete or unexpectedly duplicated."
  chmod 600 "$output" "$uuid_output" "$allowlist" "$host_allowlist"
  printf '%b\n' \
    'runtime_image_identity_scope\tEXACT_HOST_FRAMEWORK_AUTOUPDATE_UPDATER_DOWNLOADER_INSTALLER_ALL_ARCH_MACHO_UUID_AND_SHA256' \
    "runtime_image_identity_manifest_sha256\t$(release_sha256 "$output")" \
    "runtime_image_uuid_allowlist\t$(/usr/bin/paste -sd, "$allowlist")" \
    "host_executable_uuid_allowlist\t$(/usr/bin/paste -sd, "$host_allowlist")" \
    >> "$evidence_path"
}

record_installed_app() {
  local expected_version="$1" expected_build="$2" evidence_path="$3"
  local executable="$INSTALLED_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME"
  local framework_binary="$INSTALLED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
  local info_plist="$INSTALLED_APP/Contents/Info.plist"
  local framework_info="$INSTALLED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
  local manifest="$ACTIVE_PHASE_DIRECTORY/bundle-manifest.tsv"
  local stability_manifest="$ACTIVE_PHASE_DIRECTORY/bundle-manifest-stability.tsv"
  local xattrs="$ACTIVE_PHASE_DIRECTORY/installed-xattrs.tsv"
  local codesign_stderr="$ACTIVE_PHASE_DIRECTORY/installed-codesign.stderr"
  local identity_record="$ACTIVE_PHASE_DIRECTORY/installed-filesystem-identity.tsv"
  local app_stat_before app_stat_after executable_stat_before executable_stat_after
  local executable_sha_before executable_sha_after bundle_manifest_sha
  local app_device app_inode app_ctime executable_device executable_inode executable_ctime

  [[ -d "$INSTALLED_APP" && ! -L "$INSTALLED_APP" \
      && "$(cd "$INSTALLED_APP" && pwd -P)" == "$INSTALLED_APP" ]] \
    || release_die "Installed Ushot must be a canonical real application bundle at $INSTALLED_APP."
  [[ -f "$executable" && ! -L "$executable" ]] \
    || release_die "Installed Ushot executable must be regular and non-symbolic."
  app_stat_before="$(/usr/bin/stat -f '%d %i %c' "$INSTALLED_APP")" \
    || release_die "Could not capture the installed app-root filesystem identity."
  executable_stat_before="$(/usr/bin/stat -f '%d %i %c' "$executable")" \
    || release_die "Could not capture the installed executable filesystem identity."
  executable_sha_before="$(release_sha256 "$executable")"
  release_validate_app_identity "$INSTALLED_APP" "$expected_version" "$expected_build"
  release_verify_signature_mode "$INSTALLED_APP" public-adhoc
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP" \
    > /dev/null 2> "$codesign_stderr" \
    || release_die "Installed Ushot failed final strict deep code-signature validation."
  chmod 600 "$codesign_stderr"
  write_bundle_manifest "$INSTALLED_APP" "$manifest"
  bundle_manifest_sha="$(release_sha256 "$manifest")"
  record_bundle_xattrs "$INSTALLED_APP" "$xattrs" installed-system-only "$evidence_path" installed
  printf '%b\n' \
    "evidence_schema\t$EVIDENCE_SCHEMA" \
    "installed_app_path\t$INSTALLED_APP" \
    "expected_version\t$expected_version" \
    "expected_build\t$expected_build" \
    "executable_sha256\t$executable_sha_before" \
    "host_info_plist_sha256\t$(release_sha256 "$info_plist")" \
    "framework_binary_sha256\t$(release_sha256 "$framework_binary")" \
    "framework_info_plist_sha256\t$(release_sha256 "$framework_info")" \
    'bundle_manifest_scope\tCOMPLETE_TREE_PATH_TYPE_MODE_OWNER_GROUP_BSD_FLAGS_LINK_COUNT_ACL_HARDLINK_IDENTITY_SYMLINK_TARGET_SIZE_SHA256' \
    "bundle_manifest_sha256\t$bundle_manifest_sha" \
    'installed_final_codesign\tPASS' \
    >> "$evidence_path"
  record_app_policy "$INSTALLED_APP" "$evidence_path"
  record_runtime_image_identities "$INSTALLED_APP" "$evidence_path"
  record_running_app "$INSTALLED_APP" "$evidence_path"
  record_helper_snapshot "$evidence_path"
  write_bundle_manifest "$INSTALLED_APP" "$stability_manifest"
  app_stat_after="$(/usr/bin/stat -f '%d %i %c' "$INSTALLED_APP")" \
    || release_die "Could not re-sample the installed app-root filesystem identity."
  executable_stat_after="$(/usr/bin/stat -f '%d %i %c' "$executable")" \
    || release_die "Could not re-sample the installed executable filesystem identity."
  executable_sha_after="$(release_sha256 "$executable")"
  [[ "$app_stat_before" == "$app_stat_after" \
      && "$executable_stat_before" == "$executable_stat_after" \
      && "$executable_sha_before" == "$executable_sha_after" \
      && "$bundle_manifest_sha" == "$(release_sha256 "$stability_manifest")" \
      && "$(evidence_value_from_file "$evidence_path" running_executable_sha256)" == "$executable_sha_before" ]] \
    || release_die "Installed app root/executable stat or hash changed during the stable evidence snapshot."
  read -r app_device app_inode app_ctime <<< "$app_stat_before"
  read -r executable_device executable_inode executable_ctime <<< "$executable_stat_before"
  [[ "$app_device" =~ ^[0-9]+$ && "$app_inode" =~ ^[1-9][0-9]*$ && "$app_ctime" =~ ^[0-9]+$ \
      && "$executable_device" =~ ^[0-9]+$ && "$executable_inode" =~ ^[1-9][0-9]*$ && "$executable_ctime" =~ ^[0-9]+$ ]] \
    || release_die "Installed app/executable filesystem identity is malformed."
  [[ "$(evidence_value_from_file "$evidence_path" running_executable_device)" == "$executable_device" \
      && "$(evidence_value_from_file "$evidence_path" running_executable_inode)" == "$executable_inode" \
      && "$(evidence_value_from_file "$evidence_path" running_executable_ctime_epoch)" == "$executable_ctime" ]] \
    || release_die "Running executable vnode identity differs from the stable installed executable identity."
  printf '%s\t%s\t%s\t%s\t%s\n' \
    app-root "$app_device" "$app_inode" "$app_ctime" "$bundle_manifest_sha" \
    > "$identity_record"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    executable "$executable_device" "$executable_inode" "$executable_ctime" "$executable_sha_before" \
    >> "$identity_record"
  chmod 600 "$identity_record"
  printf '%b\n' \
    "installed_app_device\t$app_device" \
    "installed_app_inode\t$app_inode" \
    "installed_app_ctime_epoch\t$app_ctime" \
    "installed_app_tree_sha256\t$bundle_manifest_sha" \
    "installed_executable_device\t$executable_device" \
    "installed_executable_inode\t$executable_inode" \
    "installed_executable_ctime_epoch\t$executable_ctime" \
    "installed_executable_sha256\t$executable_sha_before" \
    "installed_filesystem_identity_sha256\t$(release_sha256 "$identity_record")" \
    'installed_filesystem_identity_stability\tTWO_STAT_AND_HASH_SNAPSHOTS_PLUS_IDENTICAL_COMPLETE_BUNDLE_MANIFESTS' \
    >> "$evidence_path"
}

baseline_integrity_paths() {
  printf '%s\n' \
    evidence.tsv \
    bundle-manifest.tsv \
    bundle-manifest-stability.tsv \
    installed-filesystem-identity.tsv \
    installed-xattrs.tsv \
    installed-codesign.stderr \
    public-baseline-bundle-manifest.tsv \
    public-baseline-xattrs.tsv \
    public-baseline-codesign.stderr \
    archive-bundle-manifest.tsv \
    archive-xattrs.tsv \
    archive-codesign.stderr \
    fixture-selected.json \
    baseline-assets.tsv \
    baseline-release-validator.stdout \
    baseline-release-validator.stderr \
    runtime-image-identities.tsv \
    process-identity-sampler.c \
    process-identity-sampler \
    process-identity-before.tsv \
    process-identity-after.tsv \
    process-identity-expected-keys.txt \
    process-identity-actual-keys.txt \
    running-executable-lsof.raw \
    running-executable-lsof.tsv \
    ushot-pids-before.txt \
    ushot-pids-after.txt \
    sparkle-helper-processes.tsv \
    helper-Autoupdate-pids.txt \
    helper-Updater-pids.txt \
    helper-Downloader-pids.txt \
    helper-Installer-pids.txt \
    helper-InstallerLauncher-pids.txt \
    result.tsv
}

write_baseline_local_integrity() {
  local output="$REPORT_DIRECTORY/baseline/local-integrity.tsv"
  local relative
  : > "$output"
  while IFS= read -r relative; do
    [[ -f "$REPORT_DIRECTORY/baseline/$relative" && ! -L "$REPORT_DIRECTORY/baseline/$relative" ]] \
      || release_die "Baseline local-integrity input is missing: $relative"
    printf '%s\t%s\n' "$(release_sha256 "$REPORT_DIRECTORY/baseline/$relative")" "$relative" >> "$output"
  done < <(baseline_integrity_paths)
  chmod 600 "$output"
}

verify_baseline_local_integrity() {
  local manifest="$REPORT_DIRECTORY/baseline/local-integrity.tsv"
  local digest relative actual count=0
  require_private_evidence_file "$manifest"
  /usr/bin/cmp -s \
    <(baseline_integrity_paths | LC_ALL=C /usr/bin/sort) \
    <(/usr/bin/awk -F '\t' 'NF == 2 { print $2 }' "$manifest" | LC_ALL=C /usr/bin/sort) \
    || release_die "Baseline local-integrity manifest does not contain the exact evidence whitelist."
  while IFS=$'\t' read -r digest relative extra; do
    [[ -z "${extra:-}" && "$digest" =~ ^[0-9a-f]{64}$ ]] \
      || release_die "Baseline local-integrity manifest is malformed."
    [[ "$(/usr/bin/awk -F '\t' -v relative="$relative" '$2 == relative {n += 1} END {print n + 0}' "$manifest")" == "1" ]] \
      || release_die "Baseline local-integrity manifest contains a duplicate path."
    require_private_phase_file "$REPORT_DIRECTORY/baseline/$relative"
    actual="$(release_sha256 "$REPORT_DIRECTORY/baseline/$relative")"
    [[ "$actual" == "$digest" ]] || release_die "Baseline local evidence changed: $relative"
    count=$((count + 1))
  done < "$manifest"
  [[ "$count" == "34" ]] || release_die "Baseline local-integrity manifest must contain exactly thirty-four entries."
  [[ "$(evidence_value_from_file "$REPORT_DIRECTORY/baseline/result.tsv" result)" == "PASS" ]] \
    || release_die "Sealed baseline result is not PASS."
}

require_report_directory() {
  local baseline="$REPORT_DIRECTORY/baseline"
  REPORT_DIRECTORY="$(require_canonical_directory "$REPORT_DIRECTORY" "Report directory")"
  [[ "$(stat -f '%u' "$REPORT_DIRECTORY")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$REPORT_DIRECTORY")" == "700" ]] \
    || release_die "Report directory must be current-user-owned with mode 0700."
  [[ -d "$baseline" && ! -L "$baseline" \
      && "$(stat -f '%u' "$baseline")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$baseline")" == "700" ]] \
    || release_die "Report directory does not contain a private real baseline directory."
  require_private_evidence_file "$baseline/evidence.tsv"
  require_private_evidence_file "$baseline/bundle-manifest.tsv"
  require_private_evidence_file "$baseline/public-baseline-bundle-manifest.tsv"
  require_private_evidence_file "$baseline/archive-bundle-manifest.tsv"
  require_private_evidence_file "$baseline/fixture-selected.json"
  require_private_evidence_file "$baseline/result.tsv"
  [[ "$(evidence_value_from_file "$baseline/result.tsv" result)" == "PASS" ]] \
    || release_die "Baseline result is not PASS."
  verify_baseline_local_integrity
  [[ "$(baseline_value expected_version)" == "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" \
      && "$(baseline_value expected_build)" == "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" \
      && "$(baseline_value fixture_case)" == "normal" ]] \
    || release_die "Baseline is not the published 0.1.3 build 4 process plus normal 0.1.4 fixture."
  [[ "$(release_sha256 "$SCRIPT_DIR/verify-update-transition.sh")" == "$(baseline_value transition_verifier_script_sha256)" \
      && "$(release_sha256 "$SCRIPT_DIR/release-common.sh")" == "$(baseline_value release_common_script_sha256)" ]] \
    || release_die "Verifier or shared release-policy source changed after the externally sealed baseline."
}

require_baseline_validator_source_identity() {
  local evidence_path="$1"
  [[ "$(evidence_value_from_file "$evidence_path" authenticated_validator_sources_sha256)" \
      == "$(baseline_value authenticated_validator_sources_sha256)" ]] \
    || release_die "App-identical authenticated-XML validator sources changed after the externally sealed baseline."
  printf 'authenticated_validator_sources_match_baseline\tPASS\n' >> "$evidence_path"
}

require_phase_execution_sources_match_baseline() {
  local evidence_path="$1"
  [[ "$(release_sha256 "$SCRIPT_DIR/verify-update-transition.sh")" == "$(baseline_value transition_verifier_script_sha256)" \
      && "$(release_sha256 "$SCRIPT_DIR/release-common.sh")" == "$(baseline_value release_common_script_sha256)" ]] \
    || release_die "Verifier or shared release-policy source changed during the evidence phase."
  printf 'phase_execution_sources_match_baseline\tPASS\n' >> "$evidence_path"
}

record_baseline_integrity_claim() {
  local evidence_path="$1"
  [[ -n "$EXPECTED_BASELINE_DIGEST" ]] \
    || record_incomplete "An externally retained baseline digest is mandatory for every negative and success verification."
  [[ "$EXPECTED_BASELINE_DIGEST" =~ ^[0-9a-f]{64}$ \
      && "$EXPECTED_BASELINE_DIGEST" == "$(release_sha256 "$REPORT_DIRECTORY/baseline/local-integrity.tsv")" ]] \
    || release_die "Externally supplied baseline digest does not match sealed local evidence."
  printf '%b\n' \
    'baseline_integrity_scope\tEXTERNALLY_SUPPLIED_EXACT_WHITELIST_DIGEST_MATCHED' \
    "baseline_local_integrity_digest\t$EXPECTED_BASELINE_DIGEST" \
    >> "$evidence_path"
}

require_account_context_matches_baseline() {
  local evidence_path="$1" key
  for key in \
    current_uid current_user console_uid console_user current_user_admin_member \
    current_account_classification clean_standard_account_final_gate; do
    [[ "$(evidence_value_from_file "$evidence_path" "$key")" == "$(baseline_value "$key")" ]] \
      || release_die "Verifier/console/admin account context changed after baseline: $key"
  done
  printf 'account_context_matches_baseline\tPASS\n' >> "$evidence_path"
}

copy_stable_evidence_input() {
  local source="$1" destination="$2" description="$3"
  local sha_before sha_after
  source="$(require_private_input_file "$source" "$description")"
  sha_before="$(release_sha256 "$source")"
  /bin/cp "$source" "$destination"
  chmod 600 "$destination"
  sha_after="$(release_sha256 "$source")"
  [[ "$sha_before" == "$sha_after" \
      && "$sha_before" == "$(release_sha256 "$destination")" ]] \
    || release_die "$description changed while it was entering the phase evidence."
}

parse_request_evidence() {
  local evidence_path="$1"
  local snapshot="$ACTIVE_PHASE_DIRECTORY/loopback-requests.tsv"
  local selected="$ACTIVE_PHASE_DIRECTORY/loopback-selected-events.tsv"
  local summary="$ACTIVE_PHASE_DIRECTORY/loopback-summary.tsv"
  local feed_count archive_count min_ms max_ms

  [[ -n "$REQUEST_EVIDENCE" && -n "$REQUEST_GENERATION" ]] \
    || record_incomplete "A request-evidence file and explicit request generation are required."
  [[ "$REQUEST_GENERATION" =~ ^[1-9][0-9]*$ ]] \
    || release_die "Request generation must be a positive decimal integer."
  copy_stable_evidence_input "$REQUEST_EVIDENCE" "$snapshot" "loopback request evidence"
  /usr/bin/ruby -rtime - "$snapshot" "$selected" "$summary" \
    "$REQUEST_EVIDENCE_SCHEMA" "$CASE_LABEL" "$REQUEST_GENERATION" \
    "$FEED_TRANSFER_MODE" "$FIXTURE_FEED_SHA256" "$FIXTURE_ARCHIVE_SHA256" \
    "$FIXTURE_FEED_SIZE" "$FIXTURE_ARCHIVE_SIZE" \
    "$(baseline_value loopback_server_script_sha256)" \
    "$(baseline_value fixture_manifest_sha256)" \
    "$(baseline_value fixture_checksums_sha256)" \
    "$(baseline_value recorded_at_epoch)" "$ACTIVE_STAGE" <<'RUBY'
source, selected_path, summary_path, expected_schema, selected_case, selected_generation,
  selected_mode, feed_sha, archive_sha, feed_size_text, archive_size_text,
  expected_script_sha, expected_manifest_sha, expected_checksums_sha,
  baseline_epoch_text, verifier_stage = ARGV
abort("request evidence is too large") if File.size(source) > 16_777_216
lines = File.readlines(source, chomp: true)
abort("request evidence is incomplete") if lines.length < 21
abort("wrong request evidence schema") unless lines.shift == "schema\t#{expected_schema}"
abort("wrong evidence role") unless lines.shift == "evidence_role\tcorroborating-only"
abort("wrong evidence limitation") unless lines.shift == "evidence_limitation\tsame-uid-file-and-probe-header-are-forgeable"
session_fields = lines.shift.split("\t", -1)
abort("malformed session_id") unless session_fields.length == 2 && session_fields[0] == "session_id" && session_fields[1].match?(/\A[0-9a-f]{16}\z/)
session_id = session_fields[1]
started_fields = lines.shift.split("\t", -1)
abort("malformed started_at_utc") unless started_fields.length == 2 && started_fields[0] == "started_at_utc"
started_time = Time.iso8601(started_fields[1])
abort("loopback session predates the sealed baseline") if started_time.to_i < Integer(baseline_epoch_text, 10)
script_fields = lines.shift.split("\t", -1)
abort("malformed or changed script_sha256") unless script_fields == ["script_sha256", expected_script_sha]
script_sha256 = script_fields[1]
ca_fields = lines.shift.split("\t", -1)
abort("malformed test_ca_sha256") unless ca_fields.length == 2 && ca_fields[0] == "test_ca_sha256" && ca_fields[1].match?(/\A[0-9A-F]{64}\z/)
test_ca_sha256 = ca_fields[1]
abort("listener is not bound to IPv4 loopback") unless lines.shift == "listener_address\t127.0.0.1"
abort("listener is not exact HTTPS port 443") unless lines.shift == "listener_port\t443"
abort("exact system probe is not mandatory") unless lines.shift == "exact_system_probe_required\ttrue"
abort("fixture manifest binding changed") unless lines.shift == "fixture_manifest_sha256\t#{expected_manifest_sha}"
abort("fixture checksum binding changed") unless lines.shift == "fixture_checksums_sha256\t#{expected_checksums_sha}"

expected_cases = %w[
  build-number-mismatch duplicate-build-metadata normal oversized-signed-feed
  short-and-build-mismatch short-version-mismatch tampered-archive
]
case_rows = {}
expected_cases.each do |expected_case|
  fields = lines.shift.to_s.split("\t", -1)
  abort("malformed or out-of-order case row") unless fields.length == 4 && fields[0] == "case" && fields[1] == expected_case && fields[2].match?(/\A[0-9a-f]{64}\z/) && fields[3].match?(/\A[0-9a-f]{64}\z/)
  case_rows[fields[1]] = fields[2, 2]
end
expected_columns = %w[columns kind sequence utc generation case feed_mode actor route method status bytes outcome]
abort("malformed columns row") unless lines.shift.to_s.split("\t", -1) == expected_columns

events = []
last_sequence = 0
last_timestamp = started_time
lines.each do |line|
  fields = line.split("\t", -1)
  abort("malformed event row") unless fields.length == 12 && fields[0] == "event"
  sequence = Integer(fields[1], 10)
  abort("event sequence must be consecutive") unless sequence == last_sequence + 1
  last_sequence = sequence
  timestamp = Time.iso8601(fields[2])
  abort("event timestamps are not monotonic") if timestamp < last_timestamp
  last_timestamp = timestamp
  generation = Integer(fields[3], 10)
  actor, route, method = fields[6], fields[7], fields[8]
  status = Integer(fields[9], 10)
  bytes = Integer(fields[10], 10)
  outcome = fields[11]
  abort("invalid outcome") unless %w[
    PASS FAIL COMPLETE CLIENT_CLOSED_AFTER_HEADERS CLIENT_CLOSED_AT_LIMIT
    CLIENT_CLOSED_EARLY ERROR
  ].include?(outcome)
  if actor == "service" && %w[service-ended cleanup].include?(route)
    abort("invalid lifecycle event") unless generation.zero? && fields[4] == "-" && fields[5] == "-" && method == "-" && status.zero? && bytes.zero? && %w[PASS FAIL].include?(outcome)
  elsif %w[service operator].include?(actor)
    expected_routes = actor == "service" ? %w[session-start exact-system-probe] : %w[case-switch mode-switch generation-complete]
    abort("invalid control event") unless generation.positive? && expected_cases.include?(fields[4]) && %w[normal chunked].include?(fields[5]) && expected_routes.include?(route) && method == "-" && status.zero? && bytes.zero? && outcome == "PASS"
  elsif %w[claimed-internal client].include?(actor)
    abort("invalid request event") unless generation.positive? && expected_cases.include?(fields[4]) && %w[normal chunked].include?(fields[5]) && %w[feed archive unmatched].include?(route) && %w[GET HEAD other].include?(method) && status.between?(100, 599) && bytes >= 0
  else
    abort("invalid event actor")
  end
  events << [sequence, (timestamp.to_r * 1000).to_i, generation, fields[4], fields[5], actor, route, method, status, bytes, outcome]
end
service_lifecycle_events = events.select do |event|
  event[5] == "service" && %w[service-ended cleanup].include?(event[6])
end
if %w[negative-verify success-verify].include?(verifier_stage)
  abort("runtime request snapshot already contains service-end or cleanup lifecycle events") \
    unless service_lifecycle_events.empty?
end
abort("selected case hash binding is absent") unless case_rows[selected_case] == [feed_sha, archive_sha]
selected_generation = Integer(selected_generation, 10)
feed_size = Integer(feed_size_text, 10)
archive_size = Integer(archive_size_text, 10)
selected_all = events.select { |event| event[2] == selected_generation && event[3] == selected_case && event[4] == selected_mode }
selected = selected_all.select { |event| event[5] == "client" }
abort("no selected client request events") if selected.empty?
abort("selected generation contains a transport error or early close") if selected_all.any? { |event| %w[FAIL ERROR CLIENT_CLOSED_EARLY].include?(event[10]) }
abort("selected generation contains an unmatched/non-GET client request") if selected.any? { |event| event[6] == "unmatched" || event[7] != "GET" }
abort("selected generation contains a non-200 client response") if selected.any? { |event| event[8] != 200 }
exact_probes = selected_all.select { |event| event[5] == "service" && event[6] == "exact-system-probe" && event[10] == "PASS" }
abort("selected generation lacks exactly one exact-system probe") unless exact_probes.length == 1
probe_receipts = selected_all.select { |event| event[5] == "claimed-internal" }
abort("selected generation lacks complete probe receipt pairs") unless probe_receipts.length >= 2 && probe_receipts.length.even?
probe_receipts.each do |event|
  expected_bytes = event[6] == "feed" ? Integer(feed_size_text, 10) : Integer(archive_size_text, 10)
  abort("exact-system probe receipt binding is invalid") \
    unless event[7] == "GET" && event[8] == 200 && event[9] == expected_bytes && event[10] == "COMPLETE"
end
probe_receipts.each_slice(2) do |pair|
  abort("a transport/exact probe does not have one feed and one archive server receipt") \
    unless pair.map { |event| event[6] }.sort == %w[archive feed]
end
exact_probe_receipts = probe_receipts.last(2)
completions = selected_all.select { |event| event[5] == "operator" && event[6] == "generation-complete" && event[10] == "PASS" }
abort("selected generation lacks exactly one operator completion") unless completions.length == 1
final_completion = completions.fetch(0)
abort("exact-system probe marker does not follow its one-time server receipt pair") unless exact_probe_receipts.map(&:first).max < exact_probes[0][0] && probe_receipts.all? { |event| event[0] < exact_probes[0][0] }
abort("exact-system probe must precede Ushot client requests") unless exact_probes[0][0] < selected.map(&:first).min
abort("the final operator completion predates a selected client request") unless final_completion[0] > selected.map(&:first).max

feed_events = selected.select { |event| event[6] == "feed" && event[8] == 200 }
archive_events = selected.select { |event| event[6] == "archive" && event[8] == 200 }
abort("selected generation must contain exactly one Ushot feed GET") unless feed_events.length == 1
transport_outcome = feed_events.fetch(0)[10]
if selected_case == "oversized-signed-feed"
  abort("oversized-feed case unexpectedly requested archive") unless archive_events.empty?
  abort("oversized feed is not actually larger than the signed-feed wire ceiling") unless feed_size > 1_049_088
  if selected_mode == "normal"
    abort("declared-length oversized feed did not close immediately after header rejection") \
      unless transport_outcome == "CLIENT_CLOSED_AFTER_HEADERS" && feed_events.fetch(0)[9] < feed_size
  else
    abort("chunked oversized feed did not close at the incremental signed-feed ceiling") \
      unless transport_outcome == "CLIENT_CLOSED_AT_LIMIT" \
        && feed_events.fetch(0)[9] >= 1_049_088 && feed_events.fetch(0)[9] < feed_size
  end
else
  abort("feed transfer did not complete exact bytes") unless feed_events.fetch(0)[9] == feed_size && transport_outcome == "COMPLETE"
  if selected_case == "duplicate-build-metadata"
    abort("raw-XML rejection case unexpectedly requested archive") unless archive_events.empty?
  else
    abort("selected generation must contain exactly one Ushot archive GET") unless archive_events.length == 1
    abort("archive transfer did not complete exact bytes") unless archive_events.fetch(0)[9] == archive_size && archive_events.fetch(0)[10] == "COMPLETE"
  end
end

File.open(selected_path, "wb", 0o600) { |file| selected.each { |event| file.puts(event.join("\t")) } }
File.open(summary_path, "wb", 0o600) do |file|
  file.puts("session_id\t#{session_id}")
  file.puts("started_at_utc\t#{started_fields[1]}")
  file.puts("script_sha256\t#{script_sha256}")
  file.puts("test_ca_sha256\t#{test_ca_sha256}")
  file.puts("listener_address\t127.0.0.1")
  file.puts("fixture_manifest_sha256\t#{expected_manifest_sha}")
  file.puts("fixture_checksums_sha256\t#{expected_checksums_sha}")
  file.puts("exact_system_probe_count\t#{exact_probes.length}")
  file.puts("all_probe_receipt_count\t#{probe_receipts.length}")
  file.puts("exact_system_probe_receipt_count\t#{exact_probe_receipts.length}")
  file.puts("generation_complete_count\t#{completions.length}")
  file.puts("service_lifecycle_event_count\t#{service_lifecycle_events.length}")
  file.puts("generation_complete_sequence\t#{final_completion[0]}")
  file.puts("generation_complete_epoch_ms\t#{final_completion[1]}")
  file.puts("feed_client_count\t#{feed_events.length}")
  file.puts("archive_client_count\t#{archive_events.length}")
  file.puts("feed_transport_outcome\t#{transport_outcome}")
  file.puts("first_client_epoch_ms\t#{selected.map { |event| event[1] }.min}")
  file.puts("last_client_epoch_ms\t#{selected.map { |event| event[1] }.max}")
end
RUBY
  chmod 600 "$selected" "$summary"
  [[ -s "$selected" ]] || record_incomplete "No client request events match the selected loopback generation, case and transfer mode."
  feed_count="$(evidence_value_from_file "$summary" feed_client_count)"
  archive_count="$(evidence_value_from_file "$summary" archive_client_count)"
  min_ms="$(evidence_value_from_file "$summary" first_client_epoch_ms)"
  max_ms="$(evidence_value_from_file "$summary" last_client_epoch_ms)"
  printf '%b\n' \
    "request_evidence_sha256\t$(release_sha256 "$snapshot")" \
    'request_evidence_role\tCORROBORATING_ONLY_SAME_UID_FORGEABLE' \
    "request_session_id\t$(evidence_value_from_file "$summary" session_id)" \
    "request_server_script_sha256\t$(evidence_value_from_file "$summary" script_sha256)" \
    "request_test_ca_sha256\t$(evidence_value_from_file "$summary" test_ca_sha256)" \
    "request_listener_address\t$(evidence_value_from_file "$summary" listener_address)" \
    'request_listener_port\t443' \
    "request_fixture_manifest_sha256\t$(evidence_value_from_file "$summary" fixture_manifest_sha256)" \
    "request_fixture_checksums_sha256\t$(evidence_value_from_file "$summary" fixture_checksums_sha256)" \
    "request_all_probe_receipt_count\t$(evidence_value_from_file "$summary" all_probe_receipt_count)" \
    "request_exact_system_probe_receipt_count\t$(evidence_value_from_file "$summary" exact_system_probe_receipt_count)" \
    'request_exact_system_probe_remote_local_effective_url_http_status_and_server_receipts\tPASS' \
    "request_generation\t$REQUEST_GENERATION" \
    "request_feed_transfer_mode\t$FEED_TRANSFER_MODE" \
    "request_feed_transport_outcome\t$(evidence_value_from_file "$summary" feed_transport_outcome)" \
    "request_feed_get_count\t$feed_count" \
    "request_archive_get_count\t$archive_count" \
    "request_first_epoch_ms\t$min_ms" \
    "request_last_epoch_ms\t$max_ms" \
    "request_generation_complete_sequence\t$(evidence_value_from_file "$summary" generation_complete_sequence)" \
    "request_generation_complete_epoch_ms\t$(evidence_value_from_file "$summary" generation_complete_epoch_ms)" \
    "request_service_lifecycle_event_count\t$(evidence_value_from_file "$summary" service_lifecycle_event_count)" \
    >> "$evidence_path"
}

capture_and_parse_app_logs() {
  local evidence_path="$1"
  local raw="$ACTIVE_PHASE_DIRECTORY/ushot-updates.ndjson"
  local parsed="$ACTIVE_PHASE_DIRECTORY/ushot-update-events.tsv"
  local baseline_epoch baseline_start floor_epoch now_epoch source_sha status expected_boot allowed_pid_one allowed_pid_two

  [[ -n "$APP_GENERATION" && "$APP_GENERATION" =~ ^[1-9][0-9]*$ ]] \
    || record_incomplete "An explicit positive Ushot app generation is required."
  baseline_epoch="$(baseline_value recorded_at_epoch)"
  baseline_start="$(baseline_value running_process_start_epoch)"
  if (( baseline_epoch > baseline_start )); then floor_epoch="$baseline_epoch"; else floor_epoch="$baseline_start"; fi
  now_epoch="$(/bin/date -u '+%s')"
  expected_boot="$(baseline_value running_boot_session_uuid)"
  allowed_pid_one="$(baseline_value running_pid)"
  allowed_pid_two="$(evidence_value_from_file "$evidence_path" running_pid)"
  if [[ -n "$APP_LOG_EVIDENCE" ]]; then
    copy_stable_evidence_input "$APP_LOG_EVIDENCE" "$raw" "Ushot update log evidence"
    printf 'app_log_source\tOPERATOR_EXPORTED_NDJSON\n' >> "$evidence_path"
  else
    set +e
    /usr/bin/log show \
      --style ndjson \
      --start "@$floor_epoch" \
      --end "@$now_epoch" \
      --predicate 'subsystem == "io.github.ischeneycc.ushot" && category == "updates"' \
      > "$raw" 2> "$ACTIVE_PHASE_DIRECTORY/log-show.stderr"
    status=$?
    set -e
    chmod 600 "$raw" "$ACTIVE_PHASE_DIRECTORY/log-show.stderr"
    [[ "$status" == "0" ]] \
      || record_incomplete "macOS unified-log query did not complete successfully."
    printf 'app_log_source\tDIRECT_READ_ONLY_LOG_SHOW_QUERY\n' >> "$evidence_path"
  fi
  source_sha="$(release_sha256 "$raw")"
  /usr/bin/ruby -rjson -rtime - "$raw" "$parsed" "$CURRENT_UID" \
    "$INSTALLED_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME" "$expected_boot" \
    "$floor_epoch" "$now_epoch" "$allowed_pid_one" "$allowed_pid_two" \
    "$(baseline_value host_executable_uuid_allowlist)" \
    "$(evidence_value_from_file "$evidence_path" host_executable_uuid_allowlist)" <<'RUBY'
source, output, expected_uid, expected_image, expected_boot, floor_epoch_text,
  ceiling_epoch_text, allowed_pid_one, allowed_pid_two, baseline_uuid_text,
  current_uuid_text = ARGV
abort("update log evidence is too large") if File.size(source) > 16_777_216
floor_epoch = Integer(floor_epoch_text, 10)
ceiling_epoch = Integer(ceiling_epoch_text, 10)
baseline_pid = Integer(allowed_pid_one, 10)
current_pid = Integer(allowed_pid_two, 10)
allowed_pids = [baseline_pid, current_pid].uniq
baseline_uuids = baseline_uuid_text.split(",", -1)
current_uuids = current_uuid_text.split(",", -1)
[baseline_uuids, current_uuids].each do |uuids|
  abort("malformed host executable UUID allowlist") unless uuids.length.between?(1, 4) && uuids.uniq.length == uuids.length && uuids.all? { |uuid| uuid.match?(/\A[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\z/) }
end
events = []
File.foreach(source) do |line|
  object = JSON.parse(line)
  next if object["finished"] == 1 && object.key?("count")
  abort("log evidence contains a record outside the privacy-safe Ushot updates predicate") \
    unless object["eventType"] == "logEvent" && object["subsystem"] == "io.github.ischeneycc.ushot" && object["category"] == "updates"
  abort("wrong update-log user") unless object["userID"].to_s == expected_uid
  abort("wrong update-log process image") unless object["processImagePath"] == expected_image
  pid = Integer(object.fetch("processID"))
  abort("update log came from an unbound PID") unless allowed_pids.include?(pid)
  process_uuid = object.fetch("processImageUUID").to_s.upcase
  permitted_uuids = if baseline_pid == current_pid
                      baseline_uuids | current_uuids
                    elsif pid == baseline_pid
                      baseline_uuids
                    else
                      current_uuids
                    end
  abort("update log came from a Ushot executable UUID outside the sealed process identity") unless permitted_uuids.include?(process_uuid)
  abort("wrong update-log boot session") unless object.fetch("bootUUID") == expected_boot
  timestamp = Time.strptime(object.fetch("timestamp"), "%Y-%m-%d %H:%M:%S.%N%z")
  abort("update log predates the baseline/process evidence floor") if timestamp.to_i < floor_epoch
  abort("update log postdates the evidence capture") if timestamp.to_i > ceiling_epoch + 5
  message = object.fetch("eventMessage")
  abort("unsafe or oversized update-log message") unless message.is_a?(String) && message.bytesize.between?(1, 4096) && !message.match?(/[\t\r\n\x00-\x08\x0b\x0c\x0e-\x1f]/)
  events << [(timestamp.to_r * 1000).to_i, pid, message]
end
File.open(output, "wb", 0o600) { |file| events.each { |event| file.puts(event.join("\t")) } }
RUBY
  chmod 600 "$parsed"
  [[ -s "$parsed" ]] || record_incomplete "No privacy-safe Ushot update log events exist in the baseline time window."
  printf '%b\n' \
    "app_log_evidence_sha256\t$source_sha" \
    "app_log_boot_session_uuid\t$expected_boot" \
    "app_log_evidence_floor_epoch\t$floor_epoch" \
    "app_log_baseline_host_uuid_allowlist\t$(baseline_value host_executable_uuid_allowlist)" \
    "app_log_current_host_uuid_allowlist\t$(evidence_value_from_file "$evidence_path" host_executable_uuid_allowlist)" \
    "app_generation\t$APP_GENERATION" \
    >> "$evidence_path"
}

capture_and_parse_sparkle_logs() {
  local evidence_path="$1"
  local raw="$ACTIVE_PHASE_DIRECTORY/sparkle-validation.ndjson"
  local parsed="$ACTIVE_PHASE_DIRECTORY/sparkle-validation-events.tsv"
  local filter_summary="$ACTIVE_PHASE_DIRECTORY/sparkle-validation-filter-summary.tsv"
  local floor_epoch baseline_epoch baseline_start now_epoch expected_boot status source_sha

  baseline_epoch="$(baseline_value recorded_at_epoch)"
  baseline_start="$(baseline_value running_process_start_epoch)"
  if (( baseline_epoch > baseline_start )); then floor_epoch="$baseline_epoch"; else floor_epoch="$baseline_start"; fi
  now_epoch="$(/bin/date -u '+%s')"
  expected_boot="$(baseline_value running_boot_session_uuid)"
  if [[ -n "$SPARKLE_LOG_EVIDENCE" ]]; then
    copy_stable_evidence_input "$SPARKLE_LOG_EVIDENCE" "$raw" "filtered Sparkle log evidence"
    printf 'sparkle_log_source\tOPERATOR_EXPORTED_FILTERED_NDJSON\n' >> "$evidence_path"
  else
    set +e
    /usr/bin/log show \
      --style ndjson \
      --start "@$floor_epoch" \
      --end "@$now_epoch" \
      --predicate 'subsystem == "org.sparkle-project.Sparkle" && category == "Sparkle" && (eventMessage BEGINSWITH "EdDSA signature does not match." || eventMessage CONTAINS "CFBundleVersion" || eventMessage CONTAINS "CFBundleShortVersionString" || eventMessage BEGINSWITH "Error: Update validation was a failure")' \
      > "$raw" 2> "$ACTIVE_PHASE_DIRECTORY/sparkle-log-show.stderr"
    status=$?
    set -e
    chmod 600 "$raw" "$ACTIVE_PHASE_DIRECTORY/sparkle-log-show.stderr"
    [[ "$status" == "0" ]] \
      || record_incomplete "Filtered Sparkle unified-log query did not complete successfully."
    printf 'sparkle_log_source\tDIRECT_READ_ONLY_FILTERED_LOG_SHOW_QUERY\n' >> "$evidence_path"
  fi
  source_sha="$(release_sha256 "$raw")"
  /usr/bin/ruby -rjson -rtime -rbase64 - "$raw" "$parsed" "$filter_summary" "$expected_boot" \
    "$floor_epoch" "$now_epoch" "$(baseline_value runtime_image_uuid_allowlist)" \
    "$CURRENT_UID" <<'RUBY'
source, output, filter_summary, expected_boot, floor_epoch_text, ceiling_epoch_text,
  uuid_allowlist_text, expected_uid = ARGV
abort("Sparkle log evidence is too large") if File.size(source) > 16_777_216
floor_epoch = Integer(floor_epoch_text, 10)
ceiling_epoch = Integer(ceiling_epoch_text, 10)
allowed_names = %w[Autoupdate Downloader Installer Updater Ushot UshotApp]
allowed_uuids = uuid_allowlist_text.split(",", -1)
abort("malformed baseline runtime-image UUID allowlist") unless allowed_uuids.length.between?(6, 24) && allowed_uuids.uniq.length == allowed_uuids.length && allowed_uuids.all? { |uuid| uuid.match?(/\A[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\z/) }
events = []
candidate_count = 0
excluded_identity_count = 0
File.foreach(source) do |line|
  object = JSON.parse(line)
  next if object["finished"] == 1 && object.key?("count")
  abort("log evidence contains a record outside the filtered Sparkle predicate") \
    unless object["eventType"] == "logEvent" && object["subsystem"] == "org.sparkle-project.Sparkle" && object["category"] == "Sparkle"
  message = object.fetch("eventMessage")
  allowed = message.start_with?("EdDSA signature does not match.") ||
    message.include?("CFBundleVersion") || message.include?("CFBundleShortVersionString") ||
    message.start_with?("Error: Update validation was a failure")
  abort("unexpected Sparkle validation message") unless allowed && message.bytesize.between?(1, 8192) && !message.match?(/[\t\r\n\x00-\x08\x0b\x0c\x0e-\x1f]/)
  candidate_count += 1
  process_uuid = object.fetch("processImageUUID").to_s.upcase
  sender_uuid = object.fetch("senderImageUUID").to_s.upcase
  unless allowed_uuids.include?(process_uuid) && allowed_uuids.include?(sender_uuid)
    excluded_identity_count += 1
    next
  end
  abort("wrong Sparkle-log boot session") unless object.fetch("bootUUID") == expected_boot
  image = object.fetch("processImagePath")
  abort("unbound Sparkle-log process image") unless image.is_a?(String) && image.start_with?("/") && allowed_names.include?(File.basename(image))
  sender_image = object.fetch("senderImagePath")
  abort("unbound Sparkle-log sender image") unless sender_image.is_a?(String) && sender_image.start_with?("/")
  abort("Sparkle-log user is neither the app user nor root") unless [expected_uid, "0"].include?(object.fetch("userID").to_s)
  pid = Integer(object.fetch("processID"))
  abort("invalid Sparkle-log PID") unless pid.positive?
  timestamp = Time.strptime(object.fetch("timestamp"), "%Y-%m-%d %H:%M:%S.%N%z")
  abort("Sparkle log predates the baseline/process evidence floor") if timestamp.to_i < floor_epoch
  abort("Sparkle log postdates evidence capture") if timestamp.to_i > ceiling_epoch + 5
  events << [
    (timestamp.to_r * 1000).to_i,
    pid,
    process_uuid,
    sender_uuid,
    Base64.strict_encode64(image),
    Base64.strict_encode64(sender_image),
    message
  ]
end
File.open(output, "wb", 0o600) { |file| events.each { |event| file.puts(event.join("\t")) } }
File.open(filter_summary, "wb", 0o600) do |file|
  file.puts("candidate_count\t#{candidate_count}")
  file.puts("excluded_identity_count\t#{excluded_identity_count}")
  file.puts("accepted_identity_count\t#{events.length}")
end
RUBY
  chmod 600 "$parsed" "$filter_summary"
  [[ -s "$parsed" ]] \
    || record_incomplete "No filtered Sparkle validation-stage event exists in the bound runtime window."
  printf '%b\n' \
    "sparkle_log_evidence_sha256\t$source_sha" \
    "sparkle_log_boot_session_uuid\t$expected_boot" \
    "sparkle_log_evidence_floor_epoch\t$floor_epoch" \
    "sparkle_log_runtime_image_uuid_allowlist\t$(baseline_value runtime_image_uuid_allowlist)" \
    "sparkle_log_candidate_count\t$(evidence_value_from_file "$filter_summary" candidate_count)" \
    "sparkle_log_excluded_identity_count\t$(evidence_value_from_file "$filter_summary" excluded_identity_count)" \
    "sparkle_log_accepted_identity_count\t$(evidence_value_from_file "$filter_summary" accepted_identity_count)" \
    >> "$evidence_path"
}

app_event_count() {
  local pid="$1" prefix="$2"
  /usr/bin/awk -F '\t' -v pid="$pid" -v prefix="$prefix" '
    $2==pid && index($3,prefix)==1 {
      if (prefix ~ /[0-9]$/ && length($3) != length(prefix) && substr($3,length(prefix)+1,1) != ",") next
      n+=1
    }
    END {print n+0}
  ' "$ACTIVE_PHASE_DIRECTORY/ushot-update-events.tsv"
}

app_event_first_ms() {
  local pid="$1" prefix="$2"
  /usr/bin/awk -F '\t' -v pid="$pid" -v prefix="$prefix" '
    $2==pid && index($3,prefix)==1 {
      if (prefix ~ /[0-9]$/ && length($3) != length(prefix) && substr($3,length(prefix)+1,1) != ",") next
      print $1; exit
    }
  ' "$ACTIVE_PHASE_DIRECTORY/ushot-update-events.tsv"
}

app_event_count_regex() {
  local pid="$1" pattern="$2"
  /usr/bin/awk -F '\t' -v pid="$pid" -v pattern="$pattern" \
    '$2 == pid && $3 ~ pattern { n += 1 } END { print n + 0 }' \
    "$ACTIVE_PHASE_DIRECTORY/ushot-update-events.tsv"
}

app_event_first_ms_regex() {
  local pid="$1" pattern="$2"
  /usr/bin/awk -F '\t' -v pid="$pid" -v pattern="$pattern" \
    '$2 == pid && $3 ~ pattern { print $1; exit }' \
    "$ACTIVE_PHASE_DIRECTORY/ushot-update-events.tsv"
}

require_app_event_regex() {
  local pid="$1" pattern="$2" description="$3" cardinality="${4:-at-least-one}"
  local count
  count="$(app_event_count_regex "$pid" "$pattern")"
  if [[ "$cardinality" == "exactly-one" ]]; then
    [[ "$count" == "1" ]] || record_incomplete "$description must occur exactly once in the bound Ushot logs."
  else
    [[ "$count" -ge 1 ]] || record_incomplete "$description is absent from the bound Ushot logs."
  fi
}

forbid_app_event_regex() {
  local pid="$1" pattern="$2" description="$3"
  [[ "$(app_event_count_regex "$pid" "$pattern")" == "0" ]] \
    || release_die "$description is forbidden for $CASE_LABEL."
}

sparkle_event_count_contains() {
  local fragment="$1" minimum_ms="$2" maximum_ms="$3"
  /usr/bin/awk -F '\t' -v fragment="$fragment" -v minimum="$minimum_ms" -v maximum="$maximum_ms" \
    '$1 >= minimum && $1 <= maximum && index($7, fragment) > 0 { n += 1 } END { print n + 0 }' \
    "$ACTIVE_PHASE_DIRECTORY/sparkle-validation-events.tsv"
}

require_sparkle_event_contains() {
  local fragment="$1" description="$2" minimum_ms="$3" maximum_ms="$4"
  [[ "$(sparkle_event_count_contains "$fragment" "$minimum_ms" "$maximum_ms")" -ge 1 ]] \
    || record_incomplete "$description is absent from filtered Sparkle validation logs."
}

require_app_event() {
  local pid="$1" prefix="$2" description="$3"
  [[ "$(app_event_count "$pid" "$prefix")" -ge 1 ]] \
    || record_incomplete "$description is absent from the selected Ushot process/generation logs."
}

verify_request_app_time_overlap() {
  local pid="$1" generation="$2"
  local app_first app_last request_first request_last
  app_first="$(app_event_first_ms "$pid" "Manual update check requested: generation=$generation")"
  app_last="$(/usr/bin/awk -F '\t' -v pid="$pid" -v comma="generation=$generation," -v suffix="generation=$generation" '$2==pid && (index($3,comma)>0 || substr($3,length($3)-length(suffix)+1)==suffix) {last=$1} END {print last}' "$ACTIVE_PHASE_DIRECTORY/ushot-update-events.tsv")"
  request_first="$(evidence_value_from_file "$ACTIVE_PHASE_DIRECTORY/evidence.tsv" request_first_epoch_ms)"
  request_last="$(evidence_value_from_file "$ACTIVE_PHASE_DIRECTORY/evidence.tsv" request_last_epoch_ms)"
  [[ -n "$app_first" && -n "$app_last" ]] \
    || record_incomplete "Could not establish the Ushot lifecycle time window."
  (( request_first + 5000 >= app_first && request_last <= app_last + 5000 )) \
    || release_die "Loopback client requests are outside the selected Ushot generation lifecycle window."
  printf 'request_and_app_log_time_window_binding\tPASS\n' >> "$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
}

verify_common_manual_generation_logs() {
  local pid="$1" generation="$APP_GENERATION"
  local requested admitted request_first
  require_app_event_regex "$pid" "^Manual update check requested: generation=$generation$" "Manual request log" exactly-one
  require_app_event_regex "$pid" "^Manual update cycle admitted: generation=$generation, checkType=0$" "Manual checkType=0 admission log" exactly-one
  requested="$(app_event_first_ms_regex "$pid" "^Manual update check requested: generation=$generation$")"
  admitted="$(app_event_first_ms_regex "$pid" "^Manual update cycle admitted: generation=$generation, checkType=0$")"
  request_first="$(evidence_value_from_file "$ACTIVE_PHASE_DIRECTORY/evidence.tsv" request_first_epoch_ms)"
  (( requested <= admitted && admitted <= request_first + 5000 )) \
    || release_die "Manual request, checkType=0 admission and first loopback request are not ordered."
}

verify_exact_cycle_terminal() {
  local pid="$1" expected_pattern="$2"
  local generation="$APP_GENERATION"
  require_app_event_regex "$pid" "$expected_pattern" "Exact terminal update-cycle log" exactly-one
  [[ "$(app_event_count_regex "$pid" "^Update cycle .*generation=$generation(,|$)")" == "1" ]] \
    || release_die "The bound generation must contain exactly one update-cycle terminal log."
}

verify_terminal_before_generation_completion() {
  local pid="$1" terminal_pattern="$2"
  local terminal_ms completion_ms request_last
  terminal_ms="$(app_event_first_ms_regex "$pid" "$terminal_pattern")"
  completion_ms="$(evidence_value_from_file "$ACTIVE_PHASE_DIRECTORY/evidence.tsv" request_generation_complete_epoch_ms)"
  request_last="$(evidence_value_from_file "$ACTIVE_PHASE_DIRECTORY/evidence.tsv" request_last_epoch_ms)"
  [[ -n "$terminal_ms" ]] || record_incomplete "Could not timestamp the exact terminal app lifecycle event."
  (( request_last <= terminal_ms + 5000 && terminal_ms <= completion_ms )) \
    || release_die "The final server generation-complete marker does not follow the app's terminal lifecycle event."
  printf 'app_terminal_epoch_ms\t%s\nserver_generation_completed_after_app_terminal\tPASS\n' \
    "$terminal_ms" >> "$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
}

forbid_common_negative_success_paths() {
  local pid="$1" generation="$APP_GENERATION"
  forbid_app_event_regex "$pid" "^(No applicable update found|Update driver ended because the app is current|Update installation authorization was cancelled|User cancelled update download): generation=$generation(,|$)" "no-update/cancellation terminal"
  forbid_app_event_regex "$pid" "^Update cycle finished( with no applicable update| after authorization cancellation)?: generation=$generation(,|$)" "no-update/cancellation cycle"
  forbid_app_event_regex "$pid" "^(Update installation requested|Admitted update relaunch with no active app work|Postponed update relaunch until active app work finishes|Resumed postponed update relaunch after app work finished|Update relaunch handoff started): generation=$generation(,|$)" "installation/relaunch success path"
}

validate_operator_attestation() {
  local evidence_path="$1" attestation_type="$2" category="$3" terminal_epoch_ms="$4"
  local snapshot="$ACTIVE_PHASE_DIRECTORY/operator-attestation.tsv"
  local summary="$ACTIVE_PHASE_DIRECTORY/operator-attestation-summary.tsv"
  local expected_type now_epoch

  [[ -n "$OPERATOR_ATTESTATION" ]] \
    || record_incomplete "A structured operator attestation is required for the visible runtime result."
  [[ "$terminal_epoch_ms" =~ ^[1-9][0-9]*$ ]] \
    || release_die "The operator attestation has no bound terminal lifecycle timestamp."
  copy_stable_evidence_input "$OPERATOR_ATTESTATION" "$snapshot" "operator attestation"
  case "$attestation_type" in
    negative) expected_type="negative-visible-error" ;;
    success) expected_type="controlled-success" ;;
    *) release_die "Unknown operator attestation type." ;;
  esac
  now_epoch="$(/bin/date -u '+%s')"
  /usr/bin/ruby -rtime - "$snapshot" "$summary" \
    "$OPERATOR_ATTESTATION_SCHEMA" "$expected_type" "$CASE_LABEL" \
    "$(evidence_value_from_file "$evidence_path" request_session_id)" \
    "$REQUEST_GENERATION" "$APP_GENERATION" "$category" \
    "$terminal_epoch_ms" "$now_epoch" <<'RUBY'
source, output, schema, expected_type, expected_case, expected_session,
  expected_request_generation, expected_app_generation, expected_category,
  terminal_epoch_ms_text, now_epoch_text = ARGV
lines = File.readlines(source, chomp: true)
common = [
  "schema\t#{schema}",
  "attestation_type\t#{expected_type}",
  "case\t#{expected_case}",
  "request_session_id\t#{expected_session}",
  "request_generation\t#{expected_request_generation}",
  "app_generation\t#{expected_app_generation}"
]
abort("operator attestation common binding mismatch") unless lines.shift(common.length) == common
observed = lines.shift.to_s.split("\t", -1)
abort("operator attestation observed_at_utc is malformed") unless observed.length == 2 && observed[0] == "observed_at_utc"
observed_time = Time.iso8601(observed[1])
terminal_time = Time.at(Integer(terminal_epoch_ms_text, 10) / 1000.0).utc
now_time = Time.at(Integer(now_epoch_text, 10)).utc
abort("operator observation predates the bound terminal lifecycle") if observed_time < terminal_time
abort("operator observation is implausibly in the future") if observed_time > now_time + 300
abort("operator attestation category mismatch") unless lines.shift == "visible_result_category\t#{expected_category}"
if expected_type == "negative-visible-error"
  abort("visible negative result was not attested") unless lines.shift == "visible_error_observed\ttrue"
else
  expected_success = [
    "no_manual_app_replacement\ttrue",
    "sparkle_update_ui_observed\ttrue",
    "sparkle_install_observed\ttrue",
    "sparkle_relaunch_observed\ttrue"
  ]
  abort("controlled success observations are incomplete") unless lines.shift(expected_success.length) == expected_success
end
abort("same-UID limitation acknowledgement is absent") unless lines.shift == "operator_acknowledges_same_uid_evidence_limitation\ttrue"
abort("operator attestation contains unexpected trailing rows") unless lines.empty?
File.open(output, "wb", 0o600) do |file|
  file.puts("observed_at_utc\t#{observed[1]}")
  file.puts("observed_at_epoch_ms\t#{(observed_time.to_r * 1000).to_i}")
end
RUBY
  chmod 600 "$summary"
  printf '%b\n' \
    "operator_attestation_sha256\t$(release_sha256 "$snapshot")" \
    "operator_attestation_type\t$expected_type" \
    "operator_attestation_category\t$category" \
    "operator_attestation_observed_at_utc\t$(evidence_value_from_file "$summary" observed_at_utc)" \
    "operator_attestation_observed_at_epoch_ms\t$(evidence_value_from_file "$summary" observed_at_epoch_ms)" \
    'operator_attestation_scope\tSTRUCTURED_OBSERVATION_NOT_INDEPENDENT_INSTALL_PROVENANCE' \
    >> "$evidence_path"
}

verify_negative_event_order() {
  local pid="$1" terminal_pattern="$2" cycle_pattern="$3"
  local generation="$APP_GENERATION"
  local requested admitted terminal cycle rejected accepted found endpoints choice download_start download_finish
  local extract_start extract_finish
  requested="$(app_event_first_ms_regex "$pid" "^Manual update check requested: generation=$generation$")"
  admitted="$(app_event_first_ms_regex "$pid" "^Manual update cycle admitted: generation=$generation, checkType=0$")"
  terminal="$(app_event_first_ms_regex "$pid" "$terminal_pattern")"
  cycle="$(app_event_first_ms_regex "$pid" "$cycle_pattern")"
  if [[ "$CASE_LABEL" == "duplicate-build-metadata" ]]; then
    rejected="$(app_event_first_ms_regex "$pid" "^Rejected authenticated appcast XML structure: generation=$generation, diagnostic=raw-xml-invalid-version-identity$")"
    (( requested <= admitted && admitted <= rejected && rejected <= terminal && terminal <= cycle )) \
      || release_die "Raw-XML rejection lifecycle is not strictly ordered."
  elif [[ "$CASE_LABEL" == "oversized-signed-feed" ]]; then
    (( requested <= admitted && admitted <= terminal && terminal <= cycle )) \
      || release_die "Oversized-feed rejection lifecycle is not strictly ordered."
  else
    accepted="$(app_event_first_ms_regex "$pid" "^Accepted authenticated appcast XML structure: generation=$generation$")"
    found="$(app_event_first_ms_regex "$pid" "^Update found: generation=$generation, version=0[.]1[.]4$")"
    endpoints="$(app_event_first_ms_regex "$pid" "^Accepted official update endpoints: generation=$generation, version=0[.]1[.]4, build=5, checkType=0$")"
    choice="$(app_event_first_ms_regex "$pid" "^User answered update prompt: generation=$generation, version=0[.]1[.]4, choice=SPUUserUpdateChoice[(]rawValue: 1[)], stage=SPUUserUpdateStage[(]rawValue: 0[)]$")"
    download_start="$(app_event_first_ms_regex "$pid" "^Update download started: generation=$generation, version=0[.]1[.]4$")"
    download_finish="$(app_event_first_ms_regex "$pid" "^Update download finished: generation=$generation, version=0[.]1[.]4$")"
    (( requested <= admitted && admitted <= accepted && accepted <= found \
        && found <= endpoints && endpoints <= choice && choice <= download_start \
        && download_start <= download_finish && download_finish <= terminal && terminal <= cycle )) \
      || release_die "Archive-validation negative lifecycle is not strictly ordered."
    if [[ "$(app_event_count_regex "$pid" "^Update extraction started: generation=$generation, version=0[.]1[.]4$")" == "1" ]]; then
      extract_start="$(app_event_first_ms_regex "$pid" "^Update extraction started: generation=$generation, version=0[.]1[.]4$")"
      extract_finish="$(app_event_first_ms_regex "$pid" "^Update extraction finished: generation=$generation, version=0[.]1[.]4$")"
      (( download_finish <= extract_start && extract_start <= extract_finish && extract_finish <= terminal )) \
        || release_die "Optional extraction callbacks are not ordered within the rejected archive lifecycle."
    fi
  fi
  printf 'negative_app_lifecycle_order\tPASS\n' >> "$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
}

verify_negative_runtime_evidence() {
  local evidence_path="$1"
  local baseline_pid generation terminal_pattern cycle_pattern category extraction_start extraction_finish validation_min validation_max
  baseline_pid="$(baseline_value running_pid)"
  generation="$APP_GENERATION"
  verify_common_manual_generation_logs "$baseline_pid"
  forbid_common_negative_success_paths "$baseline_pid"

  if [[ "$CASE_LABEL" == "duplicate-build-metadata" ]]; then
    require_app_event_regex "$baseline_pid" "^Rejected authenticated appcast XML structure: generation=$generation, diagnostic=raw-xml-invalid-version-identity$" "Authenticated raw-XML rejection log" exactly-one
    terminal_pattern="^(Update discovery ended after a policy rejection: generation=$generation, diagnostic=raw-xml-invalid-version-identity, domain=SUSparkleErrorDomain, code=1000|Update driver aborted after a policy rejection: generation=$generation, diagnostic=raw-xml-invalid-version-identity, domain=SUSparkleErrorDomain, code=1000)$"
    require_app_event_regex "$baseline_pid" "$terminal_pattern" "Outer SUAppcastParseError policy-rejection terminal" exactly-one
    cycle_pattern="^Update cycle finished after a policy rejection: generation=$generation, durationMs=[0-9]+([.][0-9]+)?, diagnostic=raw-xml-invalid-version-identity, domain=SUSparkleErrorDomain, code=1000$"
    verify_exact_cycle_terminal "$baseline_pid" "$cycle_pattern"
    forbid_app_event_regex "$baseline_pid" "^(Accepted authenticated appcast XML structure|Authenticated appcast validator returned an unexpected error type|Rejected update item metadata|Update found|Accepted official update endpoints|Update download started|Update download finished|Update extraction started|Update extraction finished): generation=$generation(,|$)" "post-raw-XML-validation lifecycle"
    category="authenticated-raw-xml-invalid-version-identity"
  elif [[ "$CASE_LABEL" == "oversized-signed-feed" ]]; then
    (( FIXTURE_FEED_SIZE > 1049088 )) \
      || release_die "Oversized fixture does not exceed the exact 1,049,088-byte signed-feed wire ceiling."
    terminal_pattern="^Update driver aborted: generation=$generation, domain=SUSparkleErrorDomain, code=2001$"
    require_app_event_regex "$baseline_pid" "$terminal_pattern" "Outer SUDownloadError oversized-feed terminal" exactly-one
    cycle_pattern="^Update cycle finished with an error: generation=$generation, durationMs=[0-9]+([.][0-9]+)?, domain=SUSparkleErrorDomain, code=2001$"
    verify_exact_cycle_terminal "$baseline_pid" "$cycle_pattern"
    forbid_app_event_regex "$baseline_pid" "^(Accepted authenticated appcast XML structure|Rejected authenticated appcast XML structure|Authenticated appcast validator returned an unexpected error type|Rejected update item metadata|Update found|Accepted official update endpoints|Update download started|Update download finished|Update extraction started|Update extraction finished): generation=$generation(,|$)" "host XML/item/archive lifecycle after the feed transport cap"
    if [[ "$FEED_TRANSFER_MODE" == "normal" ]]; then
      category="oversized-feed-content-length-rejected"
      printf 'oversized_feed_transport_boundary\tDECLARED_CONTENT_LENGTH_EXCEEDS_1049088_HEADER_REJECTION\n' >> "$evidence_path"
    else
      category="oversized-feed-incremental-limit-rejected"
      printf 'oversized_feed_transport_boundary\tCHUNKED_NO_CONTENT_LENGTH_INCREMENTAL_1049088_LIMIT\n' >> "$evidence_path"
    fi
  else
    require_app_event_regex "$baseline_pid" "^Accepted authenticated appcast XML structure: generation=$generation$" "Authenticated XML acceptance log" exactly-one
    require_app_event_regex "$baseline_pid" "^Update found: generation=$generation, version=0[.]1[.]4$" "Exact 0.1.4 update-found log" exactly-one
    require_app_event_regex "$baseline_pid" "^Accepted official update endpoints: generation=$generation, version=0[.]1[.]4, build=5, checkType=0$" "Exact endpoint/version/build/checkType acceptance log" exactly-one
    require_app_event_regex "$baseline_pid" "^User answered update prompt: generation=$generation, version=0[.]1[.]4, choice=SPUUserUpdateChoice[(]rawValue: 1[)], stage=SPUUserUpdateStage[(]rawValue: 0[)]$" "User install-choice log" exactly-one
    require_app_event_regex "$baseline_pid" "^Update download started: generation=$generation, version=0[.]1[.]4$" "Archive download start log" exactly-one
    require_app_event_regex "$baseline_pid" "^Update download finished: generation=$generation, version=0[.]1[.]4$" "Archive download completion log" exactly-one
    forbid_app_event_regex "$baseline_pid" "^(Rejected authenticated appcast XML structure|Authenticated appcast validator returned an unexpected error type|Rejected update item metadata): generation=$generation(,|$)" "raw/item policy rejection in an archive-validation fixture"
    forbid_app_event_regex "$baseline_pid" "^Update download failed: generation=$generation," "archive download failure callback"
    extraction_start="$(app_event_count_regex "$baseline_pid" "^Update extraction started: generation=$generation, version=0[.]1[.]4$")"
    extraction_finish="$(app_event_count_regex "$baseline_pid" "^Update extraction finished: generation=$generation, version=0[.]1[.]4$")"
    [[ "$extraction_start" -le 1 && "$extraction_finish" -le 1 \
        && ( "$extraction_start" == "$extraction_finish" ) ]] \
      || release_die "Optional Sparkle extraction callbacks must be absent together or appear exactly once as a pair."
    terminal_pattern="^Update driver aborted: generation=$generation, domain=SUSparkleErrorDomain, code=4005$"
    require_app_event_regex "$baseline_pid" "$terminal_pattern" "Outer SUInstallationError archive-validation terminal" exactly-one
    cycle_pattern="^Update cycle finished with an error: generation=$generation, durationMs=[0-9]+([.][0-9]+)?, domain=SUSparkleErrorDomain, code=4005$"
    verify_exact_cycle_terminal "$baseline_pid" "$cycle_pattern"
    capture_and_parse_sparkle_logs "$evidence_path"
    validation_min=$(( $(app_event_first_ms_regex "$baseline_pid" "^Update download started: generation=$generation, version=0[.]1[.]4$") - 5000 ))
    validation_max=$(( $(app_event_first_ms_regex "$baseline_pid" "$terminal_pattern") + 5000 ))
    case "$CASE_LABEL" in
      tampered-archive)
        require_sparkle_event_contains "EdDSA signature does not match. Data of the update archive being checked is different than data that has been signed" "Pre-extraction archive EdDSA mismatch" "$validation_min" "$validation_max"
        category="archive-eddsa-pre-extraction-rejected"
        ;;
      short-version-mismatch)
        require_sparkle_event_contains "The extracted application's CFBundleShortVersionString (0.1.5) does not exactly match the appcast item's sparkle:shortVersionString (0.1.4)." "Post-extraction short-version mismatch" "$validation_min" "$validation_max"
        category="post-extraction-short-version-mismatch-rejected"
        ;;
      build-number-mismatch)
        require_sparkle_event_contains "The extracted application's CFBundleVersion (6) does not exactly match the appcast item's sparkle:version (5)." "Post-extraction build-version mismatch" "$validation_min" "$validation_max"
        category="post-extraction-build-version-mismatch-rejected"
        ;;
      short-and-build-mismatch)
        require_sparkle_event_contains "The extracted application's CFBundleVersion (6) does not exactly match the appcast item's sparkle:version (5)." "Build-first mismatch for combined identity fixture" "$validation_min" "$validation_max"
        [[ "$(sparkle_event_count_contains "CFBundleShortVersionString (0.1.5) does not exactly match" "$validation_min" "$validation_max")" == "0" ]] \
          || release_die "Combined mismatch unexpectedly bypassed Sparkle's build-first identity comparison."
        category="post-extraction-build-first-mismatch-rejected"
        ;;
      *) release_die "Archive-stage negative case has no exact validation contract." ;;
    esac
    printf '%b\n' \
      'sparkle_inner_validation_code\t3002' \
      'sparkle_outer_installation_error_code\t4005' \
      'sparkle_inner_stage_binding\tPINNED_SPARKLE_RUNTIME_DIAGNOSTIC_PLUS_EXACT_FIXTURE_AND_SOURCE_SEMANTICS' \
      >> "$evidence_path"
  fi
  verify_negative_event_order "$baseline_pid" "$terminal_pattern" "$cycle_pattern"
  verify_request_app_time_overlap "$baseline_pid" "$generation"
  verify_terminal_before_generation_completion "$baseline_pid" "$cycle_pattern"
  validate_operator_attestation "$evidence_path" negative "$category" "$(evidence_value_from_file "$evidence_path" app_terminal_epoch_ms)"
  printf '%b\n' \
    "negative_rejection_category\t$category" \
    'runtime_negative_request_and_log_evidence\tPASS' \
    >> "$evidence_path"
}

verify_success_runtime_evidence() {
  local evidence_path="$1"
  local old_pid new_pid generation baseline_epoch new_start new_start_usec new_start_ms relaunch_ms new_controller_ms
  local sampler old_sample old_sample_stderr old_sample_status old_pid_disposition
  local t_requested t_admitted t_raw t_found t_endpoints t_choice t_download_start t_download_finish
  local t_extract_start t_extract_finish t_install t_relaunch
  old_pid="$(baseline_value running_pid)"
  new_pid="$(evidence_value_from_file "$evidence_path" running_pid)"
  generation="$APP_GENERATION"
  verify_common_manual_generation_logs "$old_pid"
  require_app_event_regex "$old_pid" "^Accepted authenticated appcast XML structure: generation=$generation$" "Authenticated XML acceptance log" exactly-one
  require_app_event_regex "$old_pid" "^Update found: generation=$generation, version=0[.]1[.]4$" "Exact 0.1.4 update-found log" exactly-one
  require_app_event_regex "$old_pid" "^Accepted official update endpoints: generation=$generation, version=0[.]1[.]4, build=5, checkType=0$" "Exact endpoint/version/build/checkType acceptance log" exactly-one
  require_app_event_regex "$old_pid" "^User answered update prompt: generation=$generation, version=0[.]1[.]4, choice=SPUUserUpdateChoice[(]rawValue: 1[)], stage=SPUUserUpdateStage[(]rawValue: 0[)]$" "User install-choice log" exactly-one
  require_app_event_regex "$old_pid" "^Update download started: generation=$generation, version=0[.]1[.]4$" "Archive download start log" exactly-one
  require_app_event_regex "$old_pid" "^Update download finished: generation=$generation, version=0[.]1[.]4$" "Archive download completion log" exactly-one
  require_app_event_regex "$old_pid" "^Update extraction started: generation=$generation, version=0[.]1[.]4$" "Extraction start log" exactly-one
  require_app_event_regex "$old_pid" "^Update extraction finished: generation=$generation, version=0[.]1[.]4$" "Extraction completion log" exactly-one
  require_app_event_regex "$old_pid" "^Update installation requested: generation=$generation, version=0[.]1[.]4$" "Installation request log" exactly-one
  require_app_event_regex "$old_pid" "^Update relaunch handoff started: generation=$generation$" "Relaunch handoff log" exactly-one
  require_app_event_regex "$new_pid" "^Update controller started: .*manualOnly=true, automaticDownloads=false, systemProfile=false, .*exactVersionIdentity=true, independentArchiveEdDSA=true, .*signedFeedFailureExpirationSeconds=0$" "New process update-controller startup log" exactly-one
  forbid_app_event_regex "$old_pid" "^(Update driver aborted|Update cycle finished with an error|Update cycle finished after a policy rejection): generation=$generation(,|$)" "error terminal in controlled success"
  verify_request_app_time_overlap "$old_pid" "$generation"

  t_requested="$(app_event_first_ms "$old_pid" "Manual update check requested: generation=$generation")"
  t_admitted="$(app_event_first_ms "$old_pid" "Manual update cycle admitted: generation=$generation,")"
  t_raw="$(app_event_first_ms_regex "$old_pid" "^Accepted authenticated appcast XML structure: generation=$generation$")"
  t_found="$(app_event_first_ms_regex "$old_pid" "^Update found: generation=$generation, version=0[.]1[.]4$")"
  t_endpoints="$(app_event_first_ms_regex "$old_pid" "^Accepted official update endpoints: generation=$generation, version=0[.]1[.]4, build=5, checkType=0$")"
  t_choice="$(app_event_first_ms_regex "$old_pid" "^User answered update prompt: generation=$generation, version=0[.]1[.]4, choice=SPUUserUpdateChoice[(]rawValue: 1[)], stage=SPUUserUpdateStage[(]rawValue: 0[)]$")"
  t_download_start="$(app_event_first_ms_regex "$old_pid" "^Update download started: generation=$generation, version=0[.]1[.]4$")"
  t_download_finish="$(app_event_first_ms_regex "$old_pid" "^Update download finished: generation=$generation, version=0[.]1[.]4$")"
  t_extract_start="$(app_event_first_ms_regex "$old_pid" "^Update extraction started: generation=$generation, version=0[.]1[.]4$")"
  t_extract_finish="$(app_event_first_ms_regex "$old_pid" "^Update extraction finished: generation=$generation, version=0[.]1[.]4$")"
  t_install="$(app_event_first_ms_regex "$old_pid" "^Update installation requested: generation=$generation, version=0[.]1[.]4$")"
  t_relaunch="$(app_event_first_ms_regex "$old_pid" "^Update relaunch handoff started: generation=$generation$")"
  (( t_requested <= t_admitted \
      && t_admitted <= t_raw \
      && t_raw <= t_found \
      && t_found <= t_endpoints \
      && t_endpoints <= t_choice \
      && t_choice <= t_download_start \
      && t_download_start <= t_download_finish \
      && t_download_finish <= t_extract_start \
      && t_extract_start <= t_extract_finish \
      && t_extract_finish <= t_install \
      && t_install <= t_relaunch )) \
    || release_die "Required Sparkle lifecycle logs are not in transaction order."

  baseline_epoch="$(baseline_value recorded_at_epoch)"
  new_start="$(evidence_value_from_file "$evidence_path" running_process_start_epoch)"
  (( new_start >= baseline_epoch )) \
    || release_die "The target process start time predates the recorded baseline."
  success_pid_transition_is_distinct "$old_pid" "$new_pid" \
    || release_die "Successful transition must use a PID distinct from the baseline process; PID reuse is rejected."
  [[ "$(evidence_value_from_file "$evidence_path" running_boot_session_uuid)" == "$(baseline_value running_boot_session_uuid)" ]] \
    || release_die "Controlled update evidence crossed a macOS boot-session boundary."
  sampler="$ACTIVE_PHASE_DIRECTORY/process-identity-sampler"
  old_sample="$ACTIVE_PHASE_DIRECTORY/baseline-pid-current-sample.tsv"
  old_sample_stderr="$ACTIVE_PHASE_DIRECTORY/baseline-pid-current-sample.stderr"
  [[ -f "$sampler" && ! -L "$sampler" && -x "$sampler" \
      && "$(release_sha256 "$sampler")" == "$(evidence_value_from_file "$evidence_path" process_identity_sampler_binary_sha256)" ]] \
    || release_die "The verified libproc sampler is unavailable for the old-process identity check."
  set +e
  "$sampler" "$old_pid" > "$old_sample" 2> "$old_sample_stderr"
  old_sample_status=$?
  set -e
  chmod 600 "$old_sample" "$old_sample_stderr"
  if [[ "$old_sample_status" == "0" ]]; then
    [[ "$(evidence_value_from_file "$old_sample" pid)" == "$old_pid" \
        && "$(evidence_value_from_file "$old_sample" ruid)" =~ ^[0-9]+$ \
        && "$(evidence_value_from_file "$old_sample" euid)" =~ ^[0-9]+$ \
        && "$(evidence_value_from_file "$old_sample" start_sec)" =~ ^[1-9][0-9]*$ \
        && "$(evidence_value_from_file "$old_sample" start_usec)" =~ ^[0-9]{1,6}$ ]] \
      || release_die "Old-PID libproc sampling returned malformed identity fields."
    release_die "The baseline PID is still occupied after relaunch; both the original process and PID reuse are rejected."
  else
    if ps -p "$old_pid" >/dev/null 2>&1; then
      release_die "The baseline PID still exists but its libproc identity could not be sampled."
    fi
    old_pid_disposition="BASELINE_PID_UNOCCUPIED"
  fi
  relaunch_ms="$t_relaunch"
  new_start_usec="$(evidence_value_from_file "$evidence_path" running_process_start_microseconds)"
  new_start_ms=$((new_start * 1000 + new_start_usec / 1000))
  new_controller_ms="$(app_event_first_ms_regex "$new_pid" "^Update controller started: .*manualOnly=true, automaticDownloads=false, systemProfile=false, .*exactVersionIdentity=true, independentArchiveEdDSA=true, .*signedFeedFailureExpirationSeconds=0$")"
  (( new_controller_ms >= relaunch_ms \
      && new_controller_ms >= new_start_ms - 5000 \
      && new_controller_ms <= new_start_ms + 30000 )) \
    || release_die "New process startup logs/start time are not ordered after the Sparkle relaunch handoff."
  (( new_controller_ms <= $(evidence_value_from_file "$evidence_path" request_generation_complete_epoch_ms) )) \
    || release_die "The final server generation-complete marker predates the relaunched Ushot process."
  printf 'app_terminal_epoch_ms\t%s\nserver_generation_completed_after_app_terminal\tPASS\n' \
    "$new_controller_ms" >> "$evidence_path"
  validate_operator_attestation "$evidence_path" success controlled-sparkle-update-observed "$new_controller_ms"
  printf '%b\n' \
    'runtime_success_lifecycle_chain\tMANUAL_ADMITTED_RAW_ACCEPTED_ENDPOINTS_DOWNLOAD_EXTRACT_INSTALL_RELAUNCH_NEW_PROCESS' \
    "baseline_process_post_relaunch_disposition\t$old_pid_disposition" \
    'install_provenance_boundary\tOPERATOR_ATTESTED_NOT_INDEPENDENTLY_PROVEN_BY_SAME_UID_EVIDENCE' \
    >> "$evidence_path"
}

compare_manifest_or_fail() {
  local expected="$1" actual="$2" diff="$3" message="$4" status
  if /usr/bin/cmp -s "$expected" "$actual"; then return; fi
  set +e
  /usr/bin/diff -u "$expected" "$actual" > "$diff"
  status=$?
  set -e
  chmod 600 "$diff"
  [[ "$status" == "1" ]] || release_die "Could not compare bundle manifests."
  release_die "$message"
}

write_phase_local_integrity() {
  local output="$ACTIVE_PHASE_DIRECTORY/local-integrity.tsv"
  local relative path
  : > "$output"
  while IFS= read -r -d '' path; do
    relative="${path#"$ACTIVE_PHASE_DIRECTORY"/}"
    [[ "$relative" != "$path" && "$relative" != "local-integrity.tsv" \
        && "$relative" =~ ^[A-Za-z0-9._-]+$ && -f "$path" && ! -L "$path" ]] \
      || continue
    printf '%s\t%s\n' "$(release_sha256 "$path")" "$relative" >> "$output"
  done < <(/usr/bin/find "$ACTIVE_PHASE_DIRECTORY" -mindepth 1 -maxdepth 1 -type f -print0)
  LC_ALL=C /usr/bin/sort -o "$output" "$output"
  chmod 600 "$output"
}

verify_phase_local_integrity() {
  local phase_directory="$1" expected_result="$2"
  local manifest="$phase_directory/local-integrity.tsv"
  local expected_paths="$ACTIVE_PHASE_DIRECTORY/phase-integrity-expected-paths.txt"
  local actual_paths="$ACTIVE_PHASE_DIRECTORY/phase-integrity-actual-paths.txt"
  local digest relative actual count=0 path
  require_private_evidence_file "$manifest"
  : > "$actual_paths"
  while IFS= read -r -d '' path; do
    relative="${path#"$phase_directory"/}"
    [[ "$relative" != "local-integrity.tsv" ]] && printf '%s\n' "$relative" >> "$actual_paths"
  done < <(/usr/bin/find "$phase_directory" -mindepth 1 -maxdepth 1 -type f -print0)
  LC_ALL=C /usr/bin/sort -o "$actual_paths" "$actual_paths"
  /usr/bin/awk -F '\t' 'NF == 2 { print $2 }' "$manifest" | LC_ALL=C /usr/bin/sort > "$expected_paths"
  chmod 600 "$expected_paths" "$actual_paths"
  /usr/bin/cmp -s "$expected_paths" "$actual_paths" \
    || release_die "Runtime phase integrity does not cover the exact top-level evidence-file set."
  while IFS=$'\t' read -r digest relative extra; do
    [[ -z "${extra:-}" && "$digest" =~ ^[0-9a-f]{64}$ \
        && "$relative" =~ ^[A-Za-z0-9._-]+$ ]] \
      || release_die "Runtime phase local-integrity manifest is malformed."
    [[ "$(/usr/bin/awk -F '\t' -v relative="$relative" '$2 == relative {n += 1} END {print n + 0}' "$manifest")" == "1" ]] \
      || release_die "Runtime phase local-integrity manifest contains a duplicate path."
    require_private_phase_file "$phase_directory/$relative"
    actual="$(release_sha256 "$phase_directory/$relative")"
    [[ "$actual" == "$digest" ]] || release_die "Runtime phase evidence changed: $relative"
    count=$((count + 1))
  done < "$manifest"
  [[ "$count" -ge 10 ]] || release_die "Runtime phase integrity manifest is unexpectedly incomplete."
  [[ "$(evidence_value_from_file "$phase_directory/result.tsv" result)" == "$expected_result" ]] \
    || release_die "Runtime phase result state does not match the finalization contract."
}

prepare_baseline() {
  local evidence_path baseline_digest
  ACTIVE_STAGE="baseline"
  [[ -n "$REPORT_DIRECTORY" && -n "$BASELINE_ASSETS_DIRECTORY" \
      && -n "$FIXTURES_ROOT" && "$CASE_LABEL" == "normal" ]] \
    || { usage >&2; exit 1; }
  create_report_directory "$REPORT_DIRECTORY"
  create_phase_directory baseline
  evidence_path="$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
  : > "$evidence_path"
  printf '%b\n' \
    'stage\tbaseline' \
    'evidence_scope\tEXACT_PUBLISHED_V0.1.3_ASSETS_AND_INSTALLED_TREE_PLUS_VERIFIED_NORMAL_0.1.4_FIXTURE' \
    'system_mutation\tNONE' \
    'baseline_integrity_claim\tEXACT_WHITELIST_INCLUDING_RESULT_REQUIRES_EXTERNAL_DIGEST_FOR_LATER_PHASES' \
    >> "$evidence_path"
  printf 'recorded_at_utc\t%s\nrecorded_at_epoch\t%s\n' \
    "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(/bin/date -u '+%s')" >> "$evidence_path"
  record_operator_account_context "$evidence_path"
  [[ -f "$SCRIPT_DIR/serve-update-transition-loopback.sh" \
      && ! -L "$SCRIPT_DIR/serve-update-transition-loopback.sh" \
      && "$(stat -f '%Lp' "$SCRIPT_DIR/serve-update-transition-loopback.sh")" == "755" \
      && "$(release_file_size "$SCRIPT_DIR/serve-update-transition-loopback.sh")" == "$LOOPBACK_SERVER_SIZE" \
      && "$(release_sha256 "$SCRIPT_DIR/serve-update-transition-loopback.sh")" == "$LOOPBACK_SERVER_SHA256" ]] \
    || release_die "The reviewed loopback server script is missing or symbolic."
  printf 'transition_verifier_script_sha256\t%s\nloopback_server_script_sha256\t%s\n' \
    "$(release_sha256 "$SCRIPT_DIR/verify-update-transition.sh")" \
    "$LOOPBACK_SERVER_SHA256" \
    >> "$evidence_path"
  printf 'release_common_script_sha256\t%s\n' \
    "$(release_sha256 "$SCRIPT_DIR/release-common.sh")" >> "$evidence_path"
  validate_published_baseline_assets "$evidence_path"
  safe_extract_archive \
    "$BASELINE_ASSETS_DIRECTORY/$BASELINE_ZIP_NAME" \
    "$BASELINE_VERSION" "$BASELINE_BUILD" "$evidence_path" \
    public-baseline published-baseline
  validate_fixture_root_and_case "$evidence_path"
  verify_fixture_authenticity_and_policy "$evidence_path"
  safe_extract_archive "$ARCHIVE_FIXTURE" "$USHOT_FIRST_FEED_VERSION" "$USHOT_FIRST_FEED_BUILD" "$evidence_path"
  record_installed_app "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" "$evidence_path"
  compare_manifest_or_fail \
    "$ACTIVE_PHASE_DIRECTORY/public-baseline-bundle-manifest.tsv" \
    "$ACTIVE_PHASE_DIRECTORY/bundle-manifest.tsv" \
    "$ACTIVE_PHASE_DIRECTORY/public-baseline-vs-installed-bundle.diff" \
    "Installed Ushot does not exactly match the safely extracted pinned public v0.1.3 ZIP tree."
  printf '%b\n' \
    'installed_bundle_matches_exact_published_v0.1.3_zip\tPASS' \
    'installed_quarantine_absent\tPASS' \
    >> "$evidence_path"
  [[ "$(release_sha256 "$SCRIPT_DIR/verify-update-transition.sh")" == "$(evidence_value_from_file "$evidence_path" transition_verifier_script_sha256)" \
      && "$(release_sha256 "$SCRIPT_DIR/release-common.sh")" == "$(evidence_value_from_file "$evidence_path" release_common_script_sha256)" \
      && "$(release_sha256 "$SCRIPT_DIR/serve-update-transition-loopback.sh")" == "$(evidence_value_from_file "$evidence_path" loopback_server_script_sha256)" \
      && "$(release_sha256 "$SCRIPT_DIR/validate-release-assets.sh")" == "$(evidence_value_from_file "$evidence_path" baseline_release_validator_script_sha256)" ]] \
    || release_die "A verifier/release-policy/loopback/release-validator source changed during baseline capture."
  printf 'baseline_execution_sources_stable\tPASS\n' >> "$evidence_path"
  chmod 600 "$evidence_path"
  write_result_file PASS 0
  write_baseline_local_integrity
  verify_baseline_local_integrity
  baseline_digest="$(release_sha256 "$ACTIVE_PHASE_DIRECTORY/local-integrity.tsv")"
  RESULT_RECORDED=true
  printf 'stage=baseline\nresult=PASS\nreport_directory=%s\nbaseline_digest=%s\n' \
    "$REPORT_DIRECTORY" "$baseline_digest"
}

verify_negative() {
  local evidence_path attempt_name baseline_pid current_pid runtime_digest identity_key
  ACTIVE_STAGE="negative-verify"
  [[ -n "$REPORT_DIRECTORY" && -n "$FIXTURES_ROOT" && -n "$CASE_LABEL" && "$CASE_LABEL" != "normal" ]] \
    || { usage >&2; exit 1; }
  require_report_directory
  attempt_name="negative-$CASE_LABEL-r${REQUEST_GENERATION:-missing}-a${APP_GENERATION:-missing}"
  create_phase_directory "$attempt_name"
  evidence_path="$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
  : > "$evidence_path"
  printf '%b\n' \
    'stage\tnegative-verify' \
    "case\t$CASE_LABEL" \
    'evidence_scope\tREAL_INSTALLED_0.1.3_NEGATIVE_RUNTIME_TRANSACTION' \
    'system_mutation\tNONE' \
    >> "$evidence_path"
  printf 'recorded_at_utc\t%s\nrecorded_at_epoch\t%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(/bin/date -u '+%s')" >> "$evidence_path"
  record_operator_account_context "$evidence_path"
  require_account_context_matches_baseline "$evidence_path"
  record_baseline_integrity_claim "$evidence_path"
  validate_fixture_root_and_case "$evidence_path"
  [[ "$FIXTURE_MANIFEST_SHA256" == "$(baseline_value fixture_manifest_sha256)" \
      && "$(release_sha256 "$FIXTURE_CHECKSUMS")" == "$(baseline_value fixture_checksums_sha256)" ]] \
    || release_die "Negative case does not belong to the exact baseline fixture manifest/checksum set."
  verify_fixture_authenticity_and_policy "$evidence_path"
  require_baseline_validator_source_identity "$evidence_path"
  if [[ "$FIXTURE_ARCHIVE_EDDSA" == "verified" ]]; then
    safe_extract_archive "$ARCHIVE_FIXTURE" "$FIXTURE_BUNDLE_VERSION" "$FIXTURE_BUNDLE_BUILD" "$evidence_path"
  fi
  record_installed_app "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" "$evidence_path"
  compare_manifest_or_fail \
    "$REPORT_DIRECTORY/baseline/bundle-manifest.tsv" \
    "$ACTIVE_PHASE_DIRECTORY/bundle-manifest.tsv" \
    "$ACTIVE_PHASE_DIRECTORY/bundle-manifest.diff" \
    "Negative fixture changed the installed 0.1.3 bundle."
  baseline_pid="$(baseline_value running_pid)"
  current_pid="$(evidence_value_from_file "$evidence_path" running_pid)"
  [[ "$current_pid" == "$baseline_pid" \
      && "$(evidence_value_from_file "$evidence_path" running_real_uid)" == "$(baseline_value running_real_uid)" \
      && "$(evidence_value_from_file "$evidence_path" running_effective_uid)" == "$(baseline_value running_effective_uid)" \
      && "$(evidence_value_from_file "$evidence_path" running_process_start_epoch)" == "$(baseline_value running_process_start_epoch)" \
      && "$(evidence_value_from_file "$evidence_path" running_process_start_microseconds)" == "$(baseline_value running_process_start_microseconds)" \
      && "$(evidence_value_from_file "$evidence_path" running_process_start_text)" == "$(baseline_value running_process_start_text)" \
      && "$(evidence_value_from_file "$evidence_path" running_boot_session_uuid)" == "$(baseline_value running_boot_session_uuid)" \
      && "$(evidence_value_from_file "$evidence_path" running_executable_sha256)" == "$(baseline_value running_executable_sha256)" \
      && "$(evidence_value_from_file "$evidence_path" running_lsof_txt_device)" == "$(baseline_value running_lsof_txt_device)" \
      && "$(evidence_value_from_file "$evidence_path" running_lsof_txt_inode)" == "$(baseline_value running_lsof_txt_inode)" ]] \
    || release_die "Negative fixture did not preserve the exact boot/PID/microsecond-start/executable-vnode identity."
  for identity_key in \
    installed_app_device installed_app_inode installed_app_ctime_epoch installed_app_tree_sha256 \
    installed_executable_device installed_executable_inode installed_executable_ctime_epoch \
    installed_executable_sha256 installed_filesystem_identity_sha256; do
    [[ "$(evidence_value_from_file "$evidence_path" "$identity_key")" == "$(baseline_value "$identity_key")" ]] \
      || release_die "Negative fixture changed the baseline app/executable filesystem identity: $identity_key"
  done
  parse_request_evidence "$evidence_path"
  capture_and_parse_app_logs "$evidence_path"
  verify_negative_runtime_evidence "$evidence_path"
  printf '%b\n' \
    'installed_baseline_bundle_unchanged\tPASS' \
    'baseline_app_and_executable_inodes_unchanged\tPASS' \
    'baseline_process_identity_unchanged\tBOOT_UUID_PID_LIBPROC_MICROSECOND_START_EXECUTABLE_VNODE_SHA256' \
    'runtime_verdict_boundary\tSESSION_CLEANUP_NOT_YET_VERIFIED' \
    >> "$evidence_path"
  require_phase_execution_sources_match_baseline "$evidence_path"
  chmod 600 "$evidence_path"
  write_result_file RUNTIME_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP 0
  write_phase_local_integrity
  runtime_digest="$(release_sha256 "$ACTIVE_PHASE_DIRECTORY/local-integrity.tsv")"
  RESULT_RECORDED=true
  printf 'stage=negative-verify\ncase=%s\nresult=RUNTIME_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP\nreport_directory=%s\nruntime_digest=%s\n' \
    "$CASE_LABEL" "$REPORT_DIRECTORY" "$runtime_digest"
}

validate_request_session_cleanup_tail() {
  local runtime_snapshot="$1" final_snapshot="$2" summary="$3"
  local session_id="$4" ca_sha="$5" completion_sequence="$6"
  local append_policy="$7" selected_generation="$8"
  /usr/bin/ruby -rtime - "$runtime_snapshot" "$final_snapshot" "$summary" \
    "$session_id" "$ca_sha" "$completion_sequence" "$append_policy" "$selected_generation" <<'RUBY' || return 1
runtime_path, final_path, output, expected_session, expected_ca, completion_sequence_text,
  append_policy, selected_generation_text = ARGV
abort("unknown cleanup append policy") \
  unless %w[exact_cleanup_only allow_complete_later_generations].include?(append_policy)
selected_generation = Integer(selected_generation_text, 10)
abort("selected generation must be positive") unless selected_generation.positive?
runtime = File.binread(runtime_path)
final = File.binread(final_path)
abort("runtime request evidence does not end at a complete line boundary") \
  unless !runtime.empty? && runtime.end_with?("\n")
abort("final request evidence does not end at a complete line boundary") \
  unless final.end_with?("\n")
abort("final request evidence did not strictly extend the runtime snapshot") \
  unless final.bytesize > runtime.bytesize
abort("final request evidence is not a byte-exact append-only extension") \
  unless final.start_with?(runtime)
appended = final.byteslice(runtime.bytesize, final.bytesize - runtime.bytesize)
appended_lines = appended.lines(chomp: true)
abort("cleanup append must contain complete event lines and a terminal lifecycle pair") \
  unless appended_lines.length >= 2 && appended_lines.all? { |line| !line.empty? }
runtime_lines = runtime.lines(chomp: true)
lines = final.lines(chomp: true)
abort("runtime request session binding is not unique") \
  unless runtime_lines.count("session_id\t#{expected_session}") == 1
abort("runtime request CA binding is not unique") \
  unless runtime_lines.count("test_ca_sha256\t#{expected_ca}") == 1
# macOS /usr/bin/ruby is 2.6 (no Enumerable#filter_map). Keep the protocol
# parser compatible with the system Ruby the rest of this script already requires.
events = lines.map do |line|
  fields = line.split("\t", -1)
  next unless fields[0] == "event"
  abort("malformed final event") unless fields.length == 12
  fields
end.compact
runtime_events = runtime_lines.map do |line|
  fields = line.split("\t", -1)
  next unless fields[0] == "event"
  abort("malformed runtime event") unless fields.length == 12
  fields
end.compact
abort("runtime snapshot contains no events") if runtime_events.empty?
abort("runtime snapshot already contains a service-ended or cleanup event") \
  if runtime_events.any? { |event| event[6] == "service" && %w[service-ended cleanup].include?(event[7]) }
appended_events = appended_lines.map do |line|
  fields = line.split("\t", -1)
  abort("cleanup append contains a non-event or malformed row") \
    unless fields.length == 12 && fields[0] == "event"
  fields
end
last_runtime_sequence = Integer(runtime_events.fetch(-1).fetch(1), 10)
last_appended_time = Time.iso8601(runtime_events.fetch(-1).fetch(2))
appended_events.each_with_index do |event, index|
  sequence = Integer(event[1], 10)
  abort("appended event sequence is not consecutive with the runtime snapshot") \
    unless sequence == last_runtime_sequence + index + 1
  timestamp = Time.iso8601(event[2])
  abort("appended event timestamps are not monotonic") if timestamp < last_appended_time
  last_appended_time = timestamp
  generation = Integer(event[3], 10)
  actor, route, method = event[6], event[7], event[8]
  status = Integer(event[9], 10)
  byte_count = Integer(event[10], 10)
  outcome = event[11]
  valid_cases = %w[normal tampered-archive short-version-mismatch build-number-mismatch short-and-build-mismatch duplicate-build-metadata oversized-signed-feed]
  valid_modes = %w[normal chunked]
  if actor == "service" && %w[service-ended cleanup].include?(route)
    abort("invalid appended lifecycle event") \
      unless generation.zero? && event[4] == "-" && event[5] == "-" \
        && method == "-" && status.zero? && byte_count.zero? && outcome == "PASS"
  elsif %w[service operator].include?(actor)
    expected_routes = actor == "service" ? %w[session-start exact-system-probe] : %w[case-switch mode-switch generation-complete]
    abort("invalid appended control event") \
      unless generation.positive? && valid_cases.include?(event[4]) && valid_modes.include?(event[5]) \
        && method == "-" && status.zero? && byte_count.zero? \
        && expected_routes.include?(route) && outcome == "PASS"
  elsif %w[claimed-internal client].include?(actor)
    abort("invalid appended request event") \
      unless generation.positive? && valid_cases.include?(event[4]) && valid_modes.include?(event[5]) \
        && %w[feed archive unmatched].include?(route) \
        && %w[GET HEAD other].include?(method) && status.between?(100, 599) \
        && byte_count >= 0 && %w[COMPLETE CLIENT_CLOSED_AFTER_HEADERS CLIENT_CLOSED_AT_LIMIT].include?(outcome)
  else
    abort("invalid appended event actor")
  end
end
later_events = appended_events[0...-2]
if append_policy == "exact_cleanup_only"
  abort("success cleanup append contains events before the terminal lifecycle pair") \
    unless later_events.empty?
else
  groups = []
  later_events.each do |event|
    generation = Integer(event[3], 10)
    abort("later event generation is not newer than the selected runtime generation") \
      unless generation > selected_generation
    if groups.empty? || Integer(groups.fetch(-1).fetch(0)[3], 10) != generation
      if !groups.empty?
        previous_generation = Integer(groups.fetch(-1).fetch(0)[3], 10)
        abort("later generation numbers are not strictly consecutive") \
          unless generation == previous_generation + 1
      else
        abort("first later generation is not the next generation") \
          unless generation == selected_generation + 1
      end
      groups << []
    end
    groups.fetch(-1) << event
  end
  groups.each do |group|
    generation = Integer(group.fetch(0)[3], 10)
    case_label = group.fetch(0)[4]
    feed_mode = group.fetch(0)[5]
    abort("later generation changed case/mode inside one generation") \
      unless group.all? { |event| Integer(event[3], 10) == generation && event[4] == case_label && event[5] == feed_mode }
    switch_events = group.select do |event|
      event[6] == "operator" && %w[case-switch mode-switch].include?(event[7])
    end
    abort("later generation must begin with exactly one case/mode switch") \
      unless switch_events.length == 1 && group.fetch(0) == switch_events.fetch(0)
    completions = group.select { |event| event[6] == "operator" && event[7] == "generation-complete" }
    abort("later generation must end with exactly one generation-complete") \
      unless completions.length == 1 && group.fetch(-1) == completions.fetch(0)
    abort("later generation contains an unexpected operator event") \
      unless group.select { |event| event[6] == "operator" } == [group.fetch(0), group.fetch(-1)]
    exact_probes = group.select { |event| event[6] == "service" && event[7] == "exact-system-probe" }
    abort("later generation lacks exactly one exact-system-probe") unless exact_probes.length == 1
    abort("later generation contains an unexpected service event") \
      unless group.select { |event| event[6] == "service" } == exact_probes
    probe_index = group.index(exact_probes.fetch(0))
    claimed = group.select { |event| event[6] == "claimed-internal" }
    abort("later generation lacks complete probe receipt pairs") \
      unless claimed.length >= 2 && claimed.length.even?
    abort("later generation probe receipts are not before the exact-system-probe") \
      unless claimed.all? { |event| group.index(event) < probe_index }
    claimed.each_slice(2) do |pair|
      abort("later generation probe receipt pair is not exact feed/archive GET completion") \
        unless pair.map { |event| event[7] }.sort == %w[archive feed] \
          && pair.all? { |event| event[8] == "GET" && event[9] == "200" && Integer(event[10], 10).positive? && event[11] == "COMPLETE" }
    end
    clients = group.select { |event| event[6] == "client" }
    abort("later generation client requests do not follow the exact-system-probe") \
      unless !clients.empty? && clients.all? { |event| group.index(event) > probe_index && group.index(event) < group.length - 1 }
    abort("later generation contains an unmatched or non-GET/non-200 client request") \
      if clients.any? { |event| event[7] == "unmatched" || event[8] != "GET" || event[9] != "200" }
    feed_clients = clients.select { |event| event[7] == "feed" }
    archive_clients = clients.select { |event| event[7] == "archive" }
    abort("later generation must contain exactly one feed client request") unless feed_clients.length == 1
    if case_label == "oversized-signed-feed"
      abort("later oversized generation unexpectedly requested an archive") unless archive_clients.empty?
      expected_outcome = feed_mode == "normal" ? "CLIENT_CLOSED_AFTER_HEADERS" : "CLIENT_CLOSED_AT_LIMIT"
      abort("later oversized generation has the wrong bounded transport outcome") \
        unless feed_clients.fetch(0)[11] == expected_outcome
    elsif case_label == "duplicate-build-metadata"
      abort("later duplicate-metadata generation unexpectedly requested an archive") unless archive_clients.empty?
      abort("later duplicate-metadata feed did not complete") unless feed_clients.fetch(0)[11] == "COMPLETE"
    else
      abort("later generation must contain exactly one archive client request") unless archive_clients.length == 1
      abort("later generation feed/archive requests did not complete") \
        unless feed_clients.fetch(0)[11] == "COMPLETE" && archive_clients.fetch(0)[11] == "COMPLETE"
    end
    abort("later generation contains an unclassified event") \
      unless group.length == switch_events.length + completions.length + exact_probes.length + claimed.length + clients.length
  end
end
abort("final evidence contains a failed/error/early-close outcome") \
  if events.any? { |event| %w[FAIL ERROR CLIENT_CLOSED_EARLY].include?(event[11]) }
service_ended = events.select { |event| event[6] == "service" && event[7] == "service-ended" }
cleanup = events.select { |event| event[6] == "service" && event[7] == "cleanup" }
abort("service-ended must appear exactly once") unless service_ended.length == 1
abort("cleanup must appear exactly once") unless cleanup.length == 1
expected_tail = [
  ["0", "-", "-", "service", "service-ended", "-", "0", "0", "PASS"],
  ["0", "-", "-", "service", "cleanup", "-", "0", "0", "PASS"]
]
abort("service end/cleanup are not the exact terminal two protocol events") \
  unless appended_events.last(2).map { |event| event[3, 9] } == expected_tail \
    && events.last(2) == appended_events.last(2)
end_sequence = Integer(service_ended[0][1], 10)
cleanup_sequence = Integer(cleanup[0][1], 10)
abort("cleanup lifecycle is not ordered after the final generation completion") \
  unless end_sequence > Integer(completion_sequence_text, 10) \
    && cleanup_sequence == end_sequence + 1
last_runtime_time = Time.iso8601(runtime_events.fetch(-1).fetch(2))
end_time = Time.iso8601(service_ended[0][2])
cleanup_time = Time.iso8601(cleanup[0][2])
abort("service-end timestamp predates the runtime snapshot") if end_time < last_runtime_time
abort("cleanup timestamp predates service end") if cleanup_time < end_time
File.open(output, "wb", 0o600) do |file|
  file.puts("service_ended_sequence\t#{end_sequence}")
  file.puts("service_ended_at_utc\t#{service_ended[0][2]}")
  file.puts("cleanup_sequence\t#{cleanup_sequence}")
  file.puts("cleanup_at_utc\t#{cleanup[0][2]}")
  file.puts("append_policy\t#{append_policy}")
  file.puts("later_generation_count\t#{append_policy == "exact_cleanup_only" ? 0 : later_events.map { |event| event[3] }.uniq.length}")
end
RUBY
  [[ -f "$summary" && ! -L "$summary" ]] || return 1
  chmod 600 "$summary"
}

verify_final_request_session_cleanup() {
  local runtime_phase="$1" evidence_path="$2"
  local runtime_snapshot="$runtime_phase/loopback-requests.tsv"
  local final_snapshot="$ACTIVE_PHASE_DIRECTORY/loopback-requests.tsv"
  local summary="$ACTIVE_PHASE_DIRECTORY/loopback-cleanup-summary.tsv"
  local session_id ca_sha completion_sequence hosts_marker_count keychain_match_count
  local host resolver_label resolver_output resolver_stderr resolver_status resolver_address_count
  local port_listener_status

  session_id="$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_session_id)"
  ca_sha="$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_test_ca_sha256)"
  completion_sequence="$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_generation_complete_sequence)"
  # Runtime negatives/success seal one generation; cleanup may only append the
  # terminal service-ended/cleanup pair (exact_cleanup_only).
  validate_request_session_cleanup_tail \
    "$runtime_snapshot" "$final_snapshot" "$summary" \
    "$session_id" "$ca_sha" "$completion_sequence" \
    exact_cleanup_only \
    "$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_generation)" \
    || release_die "Final request evidence is not a valid append-only protocol extension ending in exact cleanup events."

  hosts_marker_count="$(/usr/bin/awk -v marker="USHOT_UPDATE_TRANSITION_$session_id" \
    'index($0, marker) > 0 { count += 1 } END { print count + 0 }' /private/etc/hosts)"
  [[ "$hosts_marker_count" == "0" ]] \
    || release_die "Loopback hosts markers remain after recorded cleanup."

  for host in ischeneycc.github.io github.com; do
    resolver_label="${host//./-}"
    resolver_output="$ACTIVE_PHASE_DIRECTORY/resolver-$resolver_label.txt"
    resolver_stderr="$ACTIVE_PHASE_DIRECTORY/resolver-$resolver_label.stderr"
    set +e
    /usr/bin/dscacheutil -q host -a name "$host" > "$resolver_output" 2> "$resolver_stderr"
    resolver_status=$?
    set -e
    chmod 600 "$resolver_output" "$resolver_stderr"
    [[ "$resolver_status" == "0" ]] \
      || record_incomplete "The post-cleanup system resolver query failed for $host."
    resolver_address_count="$(/usr/bin/awk '
      $1 == "ip_address:" {
        if ($2 == "::1" || $2 ~ /^127[.]/) loopback += 1
        count += 1
      }
      END {
        if (loopback > 0) exit 2
        print count + 0
      }
    ' "$resolver_output")" \
      || release_die "The post-cleanup system resolver still maps $host to a loopback address."
    [[ "$resolver_address_count" -ge 1 ]] \
      || record_incomplete "The post-cleanup system resolver returned no address for $host."
  done

  /usr/bin/security find-certificate -a -Z /Library/Keychains/System.keychain \
    > "$ACTIVE_PHASE_DIRECTORY/system-keychain-certificate-hashes.txt" \
    2> "$ACTIVE_PHASE_DIRECTORY/system-keychain-inspection.stderr" \
    || release_die "Could not inspect the System keychain after loopback cleanup."
  chmod 600 "$ACTIVE_PHASE_DIRECTORY/system-keychain-certificate-hashes.txt" "$ACTIVE_PHASE_DIRECTORY/system-keychain-inspection.stderr"
  keychain_match_count="$(/usr/bin/awk -v digest="$ca_sha" '
    BEGIN { digest = toupper(digest) }
    index(toupper($0), digest) > 0 { count += 1 }
    END { print count + 0 }
  ' "$ACTIVE_PHASE_DIRECTORY/system-keychain-certificate-hashes.txt")"
  [[ "$keychain_match_count" == "0" ]] \
    || release_die "The loopback test CA remains in the System keychain after cleanup."
  set +e
  /usr/sbin/lsof -nP -iTCP:443 -sTCP:LISTEN \
    > "$ACTIVE_PHASE_DIRECTORY/port-443-listeners.txt" \
    2> "$ACTIVE_PHASE_DIRECTORY/port-443-listeners.stderr"
  port_listener_status=$?
  set -e
  chmod 600 "$ACTIVE_PHASE_DIRECTORY/port-443-listeners.txt" "$ACTIVE_PHASE_DIRECTORY/port-443-listeners.stderr"
  if [[ "$port_listener_status" == "0" ]]; then
    release_die "TCP port 443 still has a listener after the exact loopback session ended."
  fi
  [[ "$port_listener_status" == "1" ]] \
    || release_die "Could not verify that TCP port 443 is no longer listening."
  printf '%b\n' \
    'loopback_runtime_snapshot_is_exact_prefix\tPASS' \
    "loopback_service_ended_at_utc\t$(evidence_value_from_file "$summary" service_ended_at_utc)" \
    "loopback_cleanup_at_utc\t$(evidence_value_from_file "$summary" cleanup_at_utc)" \
    'loopback_service_ended\tPASS' \
    'loopback_cleanup_event\tPASS' \
    'loopback_hosts_cleanup\tPASS' \
    'loopback_system_resolver_no_longer_loopback\tPASS' \
    'loopback_system_keychain_ca_cleanup\tPASS' \
    'loopback_port_443_cleanup\tPASS' \
    >> "$evidence_path"
}

finalize_negative() {
  local evidence_path runtime_phase runtime_digest boot_uuid_before boot_uuid_after phase_boot_uuid
  ACTIVE_STAGE="finalize-negative"
  [[ -n "$REPORT_DIRECTORY" && -n "$CASE_LABEL" && "$CASE_LABEL" != "normal" \
      && -n "$REQUEST_EVIDENCE" && -n "$REQUEST_GENERATION" && -n "$APP_GENERATION" ]] \
    || { usage >&2; exit 1; }
  require_report_directory
  create_phase_directory "final-negative-$CASE_LABEL-r$REQUEST_GENERATION-a$APP_GENERATION"
  evidence_path="$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
  : > "$evidence_path"
  printf '%b\n' \
    'stage\tfinalize-negative' \
    "case\t$CASE_LABEL" \
    'evidence_scope\tSEALED_RUNTIME_PHASE_PLUS_APPEND_ONLY_SESSION_END_AND_SYSTEM_CLEANUP' \
    'system_mutation\tNONE' \
    >> "$evidence_path"
  printf 'recorded_at_utc\t%s\nrecorded_at_epoch\t%s\n' \
    "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(/bin/date -u '+%s')" >> "$evidence_path"
  record_operator_account_context "$evidence_path"
  require_account_context_matches_baseline "$evidence_path"
  record_baseline_integrity_claim "$evidence_path"
  runtime_phase="$REPORT_DIRECTORY/negative-$CASE_LABEL-r$REQUEST_GENERATION-a$APP_GENERATION"
  [[ -d "$runtime_phase" && ! -L "$runtime_phase" \
      && "$(stat -f '%u' "$runtime_phase")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$runtime_phase")" == "700" ]] \
    || release_die "The exact negative runtime phase is missing or not private."
  [[ -n "$EXPECTED_RUNTIME_DIGEST" ]] \
    || record_incomplete "An externally retained negative runtime digest is mandatory for finalization."
  [[ "$EXPECTED_RUNTIME_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Runtime digest must be a lowercase SHA-256 value."
  verify_phase_local_integrity "$runtime_phase" RUNTIME_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP
  runtime_digest="$(release_sha256 "$runtime_phase/local-integrity.tsv")"
  [[ "$runtime_digest" == "$EXPECTED_RUNTIME_DIGEST" ]] \
    || release_die "Externally supplied runtime digest does not match the sealed runtime phase."
  [[ "$(evidence_value_from_file "$runtime_phase/evidence.tsv" case)" == "$CASE_LABEL" \
      && "$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_generation)" == "$REQUEST_GENERATION" \
      && "$(evidence_value_from_file "$runtime_phase/evidence.tsv" app_generation)" == "$APP_GENERATION" \
      && "$(evidence_value_from_file "$runtime_phase/evidence.tsv" baseline_local_integrity_digest)" == "$EXPECTED_BASELINE_DIGEST" ]] \
    || release_die "Runtime phase identity does not match the requested finalization."
  phase_boot_uuid="$(evidence_value_from_file "$runtime_phase/evidence.tsv" running_boot_session_uuid)"
  boot_uuid_before="$(/usr/sbin/sysctl -n kern.bootsessionuuid)" \
    || release_die "Could not sample the boot-session UUID before negative cleanup finalization."
  [[ "$boot_uuid_before" =~ ^[0-9A-Fa-f-]{36}$ \
      && "$boot_uuid_before" == "$phase_boot_uuid" \
      && "$boot_uuid_before" == "$(baseline_value running_boot_session_uuid)" ]] \
    || release_die "Negative cleanup finalization crossed the sealed baseline/runtime boot session."
  FIXTURE_FEED_SHA256="$(evidence_value_from_file "$runtime_phase/evidence.tsv" feed_fixture_sha256)"
  FIXTURE_ARCHIVE_SHA256="$(evidence_value_from_file "$runtime_phase/evidence.tsv" archive_fixture_sha256)"
  FIXTURE_FEED_SIZE="$(evidence_value_from_file "$runtime_phase/evidence.tsv" feed_fixture_size)"
  FIXTURE_ARCHIVE_SIZE="$(evidence_value_from_file "$runtime_phase/evidence.tsv" archive_fixture_size)"
  FEED_TRANSFER_MODE="$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_feed_transfer_mode)"
  parse_request_evidence "$evidence_path"
  [[ "$(evidence_value_from_file "$evidence_path" request_session_id)" == "$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_session_id)" \
      && "$(evidence_value_from_file "$evidence_path" request_test_ca_sha256)" == "$(evidence_value_from_file "$runtime_phase/evidence.tsv" request_test_ca_sha256)" \
      && "$(evidence_value_from_file "$evidence_path" request_server_script_sha256)" == "$LOOPBACK_SERVER_SHA256" ]] \
    || release_die "Final request evidence changed the runtime session/CA/script binding."
  verify_final_request_session_cleanup "$runtime_phase" "$evidence_path"
  boot_uuid_after="$(/usr/sbin/sysctl -n kern.bootsessionuuid)" \
    || release_die "Could not re-sample the boot-session UUID after negative cleanup verification."
  [[ "$boot_uuid_after" == "$boot_uuid_before" ]] \
    || release_die "Boot-session UUID changed during negative cleanup finalization."
  require_phase_execution_sources_match_baseline "$evidence_path"
  printf '%b\n' \
    "negative_runtime_local_integrity_digest\t$runtime_digest" \
    "finalizer_boot_session_uuid_before_cleanup\t$boot_uuid_before" \
    "finalizer_boot_session_uuid_after_cleanup\t$boot_uuid_after" \
    'finalizer_boot_session_binding\tBASELINE_RUNTIME_AND_PRE_POST_CLEANUP_EXACT_MATCH' \
    'negative_runtime_result\tRUNTIME_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP' \
    'final_negative_verdict\tPASS' \
    >> "$evidence_path"
  chmod 600 "$evidence_path"
  write_result_file PASS 0
  write_phase_local_integrity
  RESULT_RECORDED=true
  printf 'stage=finalize-negative\ncase=%s\nresult=PASS\nreport_directory=%s\n' \
    "$CASE_LABEL" "$REPORT_DIRECTORY"
}

verify_success() {
  local evidence_path baseline_feed baseline_archive controlled_digest
  ACTIVE_STAGE="success-verify"
  [[ -n "$REPORT_DIRECTORY" && -n "$FIXTURES_ROOT" && "$CASE_LABEL" == "normal" ]] \
    || { usage >&2; exit 1; }
  require_report_directory
  create_phase_directory "success-r${REQUEST_GENERATION:-missing}-a${APP_GENERATION:-missing}"
  evidence_path="$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
  : > "$evidence_path"
  printf '%b\n' \
    'stage\tsuccess-verify' \
    'case\tnormal' \
    'evidence_scope\tCONTROLLED_OBSERVED_0.1.3_TO_0.1.4_WITH_UNPROVEN_REPLACEMENT_PROVENANCE' \
    'system_mutation\tNONE' \
    >> "$evidence_path"
  printf 'recorded_at_utc\t%s\nrecorded_at_epoch\t%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(/bin/date -u '+%s')" >> "$evidence_path"
  record_operator_account_context "$evidence_path"
  require_account_context_matches_baseline "$evidence_path"
  record_baseline_integrity_claim "$evidence_path"
  validate_fixture_root_and_case "$evidence_path"
  [[ "$FIXTURE_MANIFEST_SHA256" == "$(baseline_value fixture_manifest_sha256)" \
      && "$(release_sha256 "$FIXTURE_CHECKSUMS")" == "$(baseline_value fixture_checksums_sha256)" ]] \
    || release_die "Success case does not belong to the exact baseline fixture manifest/checksum set."
  baseline_feed="$(baseline_value feed_fixture_sha256)"
  baseline_archive="$(baseline_value archive_fixture_sha256)"
  [[ "$FIXTURE_FEED_SHA256" == "$baseline_feed" && "$FIXTURE_ARCHIVE_SHA256" == "$baseline_archive" ]] \
    || release_die "Success case bytes differ from the normal fixtures recorded at baseline."
  verify_fixture_authenticity_and_policy "$evidence_path"
  require_baseline_validator_source_identity "$evidence_path"
  safe_extract_archive "$ARCHIVE_FIXTURE" "$USHOT_FIRST_FEED_VERSION" "$USHOT_FIRST_FEED_BUILD" "$evidence_path"
  record_installed_app "$USHOT_FIRST_FEED_VERSION" "$USHOT_FIRST_FEED_BUILD" "$evidence_path"
  compare_manifest_or_fail \
    "$ACTIVE_PHASE_DIRECTORY/archive-bundle-manifest.tsv" \
    "$ACTIVE_PHASE_DIRECTORY/bundle-manifest.tsv" \
    "$ACTIVE_PHASE_DIRECTORY/archive-vs-installed-bundle.diff" \
    "Installed Ushot does not exactly match the safely extracted normal archive tree."
  [[ "$(evidence_value_from_file "$evidence_path" installed_app_inode)" != "$(baseline_value installed_app_inode)" \
      && "$(evidence_value_from_file "$evidence_path" installed_executable_inode)" != "$(baseline_value installed_executable_inode)" ]] \
    || release_die "Successful replacement must change both the installed app-root and executable inode."
  [[ "$(evidence_value_from_file "$evidence_path" running_lsof_txt_device)" == "$(evidence_value_from_file "$evidence_path" installed_executable_device)" \
      && "$(evidence_value_from_file "$evidence_path" running_lsof_txt_inode)" == "$(evidence_value_from_file "$evidence_path" installed_executable_inode)" ]] \
    || release_die "Relaunched Ushot process vnode is not the newly installed executable vnode."
  parse_request_evidence "$evidence_path"
  capture_and_parse_app_logs "$evidence_path"
  verify_success_runtime_evidence "$evidence_path"
  printf '%b\n' \
    'complete_installed_bundle_matches_authenticated_archive\tPASS' \
    'installed_app_and_executable_inodes_replaced\tPASS' \
    'relaunch_process_vnode_matches_replacement_executable\tPASS' \
    'installed_target_identity\t0.1.4-build-5' \
    'session_cleanup_decision\tPENDING_APPEND_ONLY_FINAL_REQUEST_TAIL_AND_SYSTEM_CLEANUP' \
    'provenance_decision\tPENDING_INDEPENDENT_EVIDENCE_OR_EXPLICIT_OWNER_ACCEPTANCE' \
    >> "$evidence_path"
  require_phase_execution_sources_match_baseline "$evidence_path"
  chmod 600 "$evidence_path"
  write_result_file CONTROLLED_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP_AND_PROVENANCE_DECISION 0
  write_phase_local_integrity
  controlled_digest="$(release_sha256 "$ACTIVE_PHASE_DIRECTORY/local-integrity.tsv")"
  RESULT_RECORDED=true
  printf 'stage=success-verify\nresult=CONTROLLED_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP_AND_PROVENANCE_DECISION\nreport_directory=%s\ncontrolled_digest=%s\n' \
    "$REPORT_DIRECTORY" "$controlled_digest"
}

finalize_success() {
  local evidence_path controlled_phase controlled_digest cleanup_digest
  local boot_uuid_before boot_uuid_after phase_boot_uuid
  ACTIVE_STAGE="finalize-success"
  [[ -n "$REPORT_DIRECTORY" && "$CASE_LABEL" == "normal" \
      && -n "$REQUEST_EVIDENCE" && -n "$REQUEST_GENERATION" && -n "$APP_GENERATION" ]] \
    || { usage >&2; exit 1; }
  require_report_directory
  create_phase_directory "final-success-r$REQUEST_GENERATION-a$APP_GENERATION"
  evidence_path="$ACTIVE_PHASE_DIRECTORY/evidence.tsv"
  : > "$evidence_path"
  printf '%b\n' \
    'stage\tfinalize-success' \
    'case\tnormal' \
    'evidence_scope\tSEALED_CONTROLLED_PHASE_PLUS_APPEND_ONLY_SESSION_END_AND_SYSTEM_CLEANUP_WITH_PROVENANCE_STILL_UNDECIDED' \
    'system_mutation\tNONE' \
    >> "$evidence_path"
  printf 'recorded_at_utc\t%s\nrecorded_at_epoch\t%s\n' \
    "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(/bin/date -u '+%s')" >> "$evidence_path"
  record_operator_account_context "$evidence_path"
  require_account_context_matches_baseline "$evidence_path"
  record_baseline_integrity_claim "$evidence_path"

  controlled_phase="$REPORT_DIRECTORY/success-r$REQUEST_GENERATION-a$APP_GENERATION"
  [[ -d "$controlled_phase" && ! -L "$controlled_phase" \
      && "$(stat -f '%u' "$controlled_phase")" == "$CURRENT_UID" \
      && "$(stat -f '%Lp' "$controlled_phase")" == "700" ]] \
    || release_die "The exact controlled success phase is missing or not private."
  [[ -n "$EXPECTED_CONTROLLED_DIGEST" ]] \
    || record_incomplete "An externally retained controlled success digest is mandatory for cleanup finalization."
  [[ "$EXPECTED_CONTROLLED_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Controlled digest must be a lowercase SHA-256 value."
  verify_phase_local_integrity \
    "$controlled_phase" \
    CONTROLLED_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP_AND_PROVENANCE_DECISION
  controlled_digest="$(release_sha256 "$controlled_phase/local-integrity.tsv")"
  [[ "$controlled_digest" == "$EXPECTED_CONTROLLED_DIGEST" ]] \
    || release_die "Externally supplied controlled digest does not match the sealed success phase."
  [[ "$(evidence_value_from_file "$controlled_phase/evidence.tsv" case)" == "normal" \
      && "$(evidence_value_from_file "$controlled_phase/evidence.tsv" request_generation)" == "$REQUEST_GENERATION" \
      && "$(evidence_value_from_file "$controlled_phase/evidence.tsv" app_generation)" == "$APP_GENERATION" \
      && "$(evidence_value_from_file "$controlled_phase/evidence.tsv" baseline_local_integrity_digest)" == "$EXPECTED_BASELINE_DIGEST" \
      && "$(evidence_value_from_file "$controlled_phase/evidence.tsv" provenance_decision)" == "PENDING_INDEPENDENT_EVIDENCE_OR_EXPLICIT_OWNER_ACCEPTANCE" ]] \
    || release_die "Controlled phase identity/provenance boundary does not match the requested cleanup finalization."
  [[ "$(evidence_value_from_file "$controlled_phase/evidence.tsv" current_uid)" == "$CURRENT_UID" \
      && "$(evidence_value_from_file "$controlled_phase/evidence.tsv" current_account_classification)" == "$(evidence_value_from_file "$evidence_path" current_account_classification)" \
      && "$(evidence_value_from_file "$controlled_phase/evidence.tsv" clean_standard_account_final_gate)" == "$(evidence_value_from_file "$evidence_path" clean_standard_account_final_gate)" ]] \
    || release_die "Controlled phase account classification changed before cleanup finalization."
  phase_boot_uuid="$(evidence_value_from_file "$controlled_phase/evidence.tsv" running_boot_session_uuid)"
  boot_uuid_before="$(/usr/sbin/sysctl -n kern.bootsessionuuid)" \
    || release_die "Could not sample the boot-session UUID before controlled cleanup finalization."
  [[ "$boot_uuid_before" =~ ^[0-9A-Fa-f-]{36}$ \
      && "$boot_uuid_before" == "$phase_boot_uuid" \
      && "$boot_uuid_before" == "$(baseline_value running_boot_session_uuid)" ]] \
    || release_die "Controlled cleanup finalization crossed the sealed baseline/success boot session."

  FIXTURE_FEED_SHA256="$(evidence_value_from_file "$controlled_phase/evidence.tsv" feed_fixture_sha256)"
  FIXTURE_ARCHIVE_SHA256="$(evidence_value_from_file "$controlled_phase/evidence.tsv" archive_fixture_sha256)"
  FIXTURE_FEED_SIZE="$(evidence_value_from_file "$controlled_phase/evidence.tsv" feed_fixture_size)"
  FIXTURE_ARCHIVE_SIZE="$(evidence_value_from_file "$controlled_phase/evidence.tsv" archive_fixture_size)"
  FEED_TRANSFER_MODE="$(evidence_value_from_file "$controlled_phase/evidence.tsv" request_feed_transfer_mode)"
  parse_request_evidence "$evidence_path"
  [[ "$(evidence_value_from_file "$evidence_path" request_session_id)" == "$(evidence_value_from_file "$controlled_phase/evidence.tsv" request_session_id)" \
      && "$(evidence_value_from_file "$evidence_path" request_test_ca_sha256)" == "$(evidence_value_from_file "$controlled_phase/evidence.tsv" request_test_ca_sha256)" \
      && "$(evidence_value_from_file "$evidence_path" request_server_script_sha256)" == "$LOOPBACK_SERVER_SHA256" ]] \
    || release_die "Final success request evidence changed the controlled session/CA/script binding."
  verify_final_request_session_cleanup "$controlled_phase" "$evidence_path"
  boot_uuid_after="$(/usr/sbin/sysctl -n kern.bootsessionuuid)" \
    || release_die "Could not re-sample the boot-session UUID after controlled cleanup verification."
  [[ "$boot_uuid_after" == "$boot_uuid_before" ]] \
    || release_die "Boot-session UUID changed during controlled cleanup finalization."
  require_phase_execution_sources_match_baseline "$evidence_path"
  printf '%b\n' \
    "controlled_runtime_local_integrity_digest\t$controlled_digest" \
    "finalizer_boot_session_uuid_before_cleanup\t$boot_uuid_before" \
    "finalizer_boot_session_uuid_after_cleanup\t$boot_uuid_after" \
    'finalizer_boot_session_binding\tBASELINE_CONTROLLED_AND_PRE_POST_CLEANUP_EXACT_MATCH' \
    'controlled_runtime_result\tCONTROLLED_VERIFICATION_COMPLETE_PENDING_SESSION_CLEANUP_AND_PROVENANCE_DECISION' \
    'session_cleanup_decision\tVERIFIED_COMPLETE' \
    'provenance_decision\tPENDING_INDEPENDENT_EVIDENCE_OR_EXPLICIT_OWNER_ACCEPTANCE' \
    'clean_standard_account_release_gate\tNOT_SATISFIED_BY_THIS_CONTROLLED_ACCOUNT_RUN' \
    >> "$evidence_path"
  chmod 600 "$evidence_path"
  write_result_file CONTROLLED_VERIFICATION_COMPLETE_PENDING_PROVENANCE_DECISION 0
  write_phase_local_integrity
  cleanup_digest="$(release_sha256 "$ACTIVE_PHASE_DIRECTORY/local-integrity.tsv")"
  RESULT_RECORDED=true
  printf 'stage=finalize-success\nresult=CONTROLLED_VERIFICATION_COMPLETE_PENDING_PROVENANCE_DECISION\nreport_directory=%s\ncleanup_digest=%s\n' \
    "$REPORT_DIRECTORY" "$cleanup_digest"
}

run_self_test() {
  (
    local self_test_root valid_raw valid_parsed duplicate_raw mismatch_raw malformed_raw
    local spaced_directory spaced_executable expected_device expected_inode
    local sampler sample_one sample_two tuple_base tuple_same tuple_ruid tuple_euid tuple_usec
    local self_test_pid self_test_root_device self_test_root_inode
    local cleanup_runtime cleanup_final cleanup_summary cleanup_runtime_with_tail cleanup_final_after_tail
    local cleanup_equal cleanup_truncated cleanup_flipped cleanup_inserted
    self_test_root="$(/usr/bin/mktemp -d "/private/tmp/ushot-transition-verifier-self-test.XXXXXX")" \
      || release_die "Could not create the verifier self-test directory."
    [[ "$self_test_root" == /private/tmp/ushot-transition-verifier-self-test.* \
        && -d "$self_test_root" && ! -L "$self_test_root" \
        && "$(cd "$self_test_root" && pwd -P)" == "$self_test_root" \
        && "$(stat -f '%u' "$self_test_root")" == "$CURRENT_UID" \
        && "$(stat -f '%Lp' "$self_test_root")" == "700" ]] \
      || release_die "Verifier self-test directory identity is invalid."
    self_test_root_device="$(/usr/bin/stat -f '%d' "$self_test_root")"
    self_test_root_inode="$(/usr/bin/stat -f '%i' "$self_test_root")"
    spaced_directory="$self_test_root/path with spaces"
    cleanup_self_test() {
      [[ "$self_test_root" == /private/tmp/ushot-transition-verifier-self-test.* \
          && -d "$self_test_root" && ! -L "$self_test_root" \
          && "$(cd "$self_test_root" && pwd -P)" == "$self_test_root" \
          && "$(/usr/bin/stat -f '%u' "$self_test_root")" == "$CURRENT_UID" \
          && "$(/usr/bin/stat -f '%d' "$self_test_root")" == "$self_test_root_device" \
          && "$(/usr/bin/stat -f '%i' "$self_test_root")" == "$self_test_root_inode" ]] \
        || return 1
      /usr/bin/find "$self_test_root" -type f -delete
      [[ ! -d "$spaced_directory" ]] || /bin/rmdir "$spaced_directory"
      /bin/rmdir "$self_test_root"
    }
    trap cleanup_self_test EXIT
    ACTIVE_PHASE_DIRECTORY="$self_test_root"
    valid_raw="$self_test_root/valid-lsof.raw"
    valid_parsed="$self_test_root/valid-lsof.tsv"
    duplicate_raw="$self_test_root/duplicate-lsof.raw"
    mismatch_raw="$self_test_root/mismatch-lsof.raw"
    malformed_raw="$self_test_root/malformed-lsof.raw"
    spaced_executable="$spaced_directory/Ushot Test Executable"
    /bin/mkdir -m 700 "$spaced_directory"
    /usr/bin/touch "$spaced_executable"
    chmod 600 "$spaced_executable"
    expected_device="$(/usr/bin/stat -f '%d' "$spaced_executable")"
    expected_inode="$(/usr/bin/stat -f '%i' "$spaced_executable")"

    printf 'p4242\nftxt\nD%s\ni22\nn/usr/lib/dyld\nftxt\nD%s\ni%s\nn%s\n' \
      "$expected_device" "$expected_device" "$expected_inode" "$spaced_executable" > "$valid_raw"
    parse_lsof_text_identity \
      "$valid_raw" "$spaced_executable" 4242 "$valid_parsed" \
      || release_die "Synthetic lsof parser acceptance test failed."
    [[ "$(evidence_value_from_file "$valid_parsed" path)" == "$spaced_executable" \
        && "$(evidence_value_from_file "$valid_parsed" device)" == "$expected_device" \
        && "$(evidence_value_from_file "$valid_parsed" inode)" == "$expected_inode" ]] \
      || release_die "Synthetic lsof parser acceptance values are wrong."

    printf 'p4242\nftxt\nD%s\ni%s\nn%s\nftxt\nD%s\ni%s\nn%s\n' \
      "$expected_device" "$expected_inode" "$spaced_executable" \
      "$expected_device" "$expected_inode" "$spaced_executable" > "$duplicate_raw"
    if parse_lsof_text_identity \
      "$duplicate_raw" "$spaced_executable" 4242 \
      "$self_test_root/unexpected-duplicate.tsv" >/dev/null 2>&1; then
      release_die "Synthetic duplicate executable txt records were accepted."
    fi

    cat > "$mismatch_raw" <<'LSOF_MISMATCH'
p4242
ftxt
D0x1000011
i22
n/usr/lib/dyld
LSOF_MISMATCH
    if parse_lsof_text_identity \
      "$mismatch_raw" "$spaced_executable" 4242 \
      "$self_test_root/unexpected-mismatch.tsv" >/dev/null 2>&1; then
      release_die "Synthetic missing executable txt record was accepted."
    fi

    printf 'p4242\nftxt\nD%s\nn%s\n' \
      "$expected_device" "$spaced_executable" > "$malformed_raw"
    if parse_lsof_text_identity \
      "$malformed_raw" "$spaced_executable" 4242 \
      "$self_test_root/unexpected-malformed.tsv" >/dev/null 2>&1; then
      release_die "Synthetic incomplete executable txt record was accepted."
    fi

    sampler="$(compile_process_identity_sampler)"
    sample_one="$self_test_root/self-process-one.tsv"
    sample_two="$self_test_root/self-process-two.tsv"
    self_test_pid="${BASHPID:-}"
    if [[ -z "$self_test_pid" ]]; then
      self_test_pid="$(/bin/sh -c 'printf "%s" "$PPID"')"
    fi
    [[ "$self_test_pid" =~ ^[1-9][0-9]*$ ]] \
      || release_die "Could not resolve the current self-test subshell PID."
    sample_process_identity "$sampler" "$self_test_pid" "$sample_one"
    sample_process_identity "$sampler" "$self_test_pid" "$sample_two"
    process_identity_samples_match "$sample_one" "$sample_two" \
      || release_die "libproc self-process identity was not stable across two samples."
    [[ "$(evidence_value_from_file "$sample_one" ruid)" == "$CURRENT_UID" \
        && "$(evidence_value_from_file "$sample_one" euid)" == "$CURRENT_UID" ]] \
      || release_die "libproc self-process UID values do not match the verifier user."

    tuple_base="$self_test_root/tuple-base.tsv"
    tuple_same="$self_test_root/tuple-same.tsv"
    tuple_ruid="$self_test_root/tuple-ruid.tsv"
    tuple_euid="$self_test_root/tuple-euid.tsv"
    tuple_usec="$self_test_root/tuple-usec.tsv"
    printf 'pid\t42\nruid\t501\neuid\t501\nstart_sec\t1000\nstart_usec\t123456\n' > "$tuple_base"
    /bin/cp "$tuple_base" "$tuple_same"
    printf 'pid\t42\nruid\t502\neuid\t501\nstart_sec\t1000\nstart_usec\t123456\n' > "$tuple_ruid"
    printf 'pid\t42\nruid\t501\neuid\t502\nstart_sec\t1000\nstart_usec\t123456\n' > "$tuple_euid"
    printf 'pid\t42\nruid\t501\neuid\t501\nstart_sec\t1000\nstart_usec\t123457\n' > "$tuple_usec"
    chmod 600 "$tuple_base" "$tuple_same" "$tuple_ruid" "$tuple_euid" "$tuple_usec"
    process_identity_samples_match "$tuple_base" "$tuple_same" \
      || release_die "Identical synthetic process tuples did not match."
    if process_identity_samples_match "$tuple_base" "$tuple_ruid"; then
      release_die "Synthetic real-UID tuple mutation was accepted."
    fi
    if process_identity_samples_match "$tuple_base" "$tuple_euid"; then
      release_die "Synthetic effective-UID tuple mutation was accepted."
    fi
    if process_identity_samples_match "$tuple_base" "$tuple_usec"; then
      release_die "Synthetic microsecond-start tuple mutation was accepted."
    fi
    if success_pid_transition_is_distinct 42 42; then
      release_die "Synthetic successful-transition PID reuse was accepted."
    fi
    success_pid_transition_is_distinct 42 43 \
      || release_die "Synthetic distinct successful-transition PID was rejected."

    cleanup_runtime="$self_test_root/cleanup-runtime.tsv"
    cleanup_final="$self_test_root/cleanup-final.tsv"
    cleanup_summary="$self_test_root/cleanup-summary.tsv"
    cleanup_runtime_with_tail="$self_test_root/cleanup-runtime-with-tail.tsv"
    cleanup_final_after_tail="$self_test_root/cleanup-final-after-tail.tsv"
    cleanup_equal="$self_test_root/cleanup-equal.tsv"
    cleanup_truncated="$self_test_root/cleanup-truncated.tsv"
    cleanup_flipped="$self_test_root/cleanup-flipped.tsv"
    cleanup_inserted="$self_test_root/cleanup-inserted.tsv"
    # Use ANSI-C quoting so \t becomes a real TAB for the TSV protocol.
    printf '%s\n' \
      $'session_id\t0123456789abcdef' \
      $'test_ca_sha256\tAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
      $'event\t1\t2026-08-06T00:00:00Z\t1\tnormal\tnormal\toperator\tgeneration-complete\t-\t0\t0\tPASS' \
      > "$cleanup_runtime"
    /bin/cp "$cleanup_runtime" "$cleanup_final"
    printf '%s\n' \
      $'event\t2\t2026-08-06T00:00:01Z\t0\t-\t-\tservice\tservice-ended\t-\t0\t0\tPASS' \
      $'event\t3\t2026-08-06T00:00:02Z\t0\t-\t-\tservice\tcleanup\t-\t0\t0\tPASS' \
      >> "$cleanup_final"
    validate_request_session_cleanup_tail \
      "$cleanup_runtime" "$cleanup_final" "$cleanup_summary" \
      0123456789abcdef AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 1 \
      exact_cleanup_only 1 \
      || release_die "Exact synthetic two-event cleanup append was rejected."

    /bin/cp "$cleanup_final" "$cleanup_runtime_with_tail"
    /bin/cp "$cleanup_runtime_with_tail" "$cleanup_final_after_tail"
    printf '%s\n' \
      $'event\t4\t2026-08-06T00:00:03Z\t0\t-\t-\tservice\tservice-ended\t-\t0\t0\tPASS' \
      $'event\t5\t2026-08-06T00:00:04Z\t0\t-\t-\tservice\tcleanup\t-\t0\t0\tPASS' \
      >> "$cleanup_final_after_tail"
    if validate_request_session_cleanup_tail \
      "$cleanup_runtime_with_tail" "$cleanup_final_after_tail" \
      "$self_test_root/unexpected-pre-tailed-summary.tsv" \
      0123456789abcdef AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 1 \
      exact_cleanup_only 1 \
      >/dev/null 2>&1; then
      release_die "Synthetic runtime snapshot with a pre-existing cleanup tail was accepted."
    fi

    /bin/cp "$cleanup_runtime" "$cleanup_equal"
    if validate_request_session_cleanup_tail \
      "$cleanup_runtime" "$cleanup_equal" "$self_test_root/unexpected-equal-summary.tsv" \
      0123456789abcdef AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 1 \
      exact_cleanup_only 1 \
      >/dev/null 2>&1; then
      release_die "Synthetic equal runtime/final request evidence was accepted."
    fi

    /usr/bin/ruby -e 'data = File.binread(ARGV.fetch(0)); File.binwrite(ARGV.fetch(1), data.byteslice(0, data.bytesize - 1))' \
      "$cleanup_final" "$cleanup_truncated"
    if validate_request_session_cleanup_tail \
      "$cleanup_runtime" "$cleanup_truncated" "$self_test_root/unexpected-truncated-summary.tsv" \
      0123456789abcdef AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 1 \
      exact_cleanup_only 1 \
      >/dev/null 2>&1; then
      release_die "Synthetic truncated cleanup append was accepted."
    fi

    /usr/bin/ruby -e 'data = File.binread(ARGV.fetch(0)); data.setbyte(0, data.getbyte(0) ^ 1); File.binwrite(ARGV.fetch(1), data)' \
      "$cleanup_final" "$cleanup_flipped"
    if validate_request_session_cleanup_tail \
      "$cleanup_runtime" "$cleanup_flipped" "$self_test_root/unexpected-flipped-summary.tsv" \
      0123456789abcdef AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 1 \
      exact_cleanup_only 1 \
      >/dev/null 2>&1; then
      release_die "Synthetic byte-flipped cleanup evidence was accepted."
    fi

    /bin/cp "$cleanup_runtime" "$cleanup_inserted"
    printf '%s\n' \
      $'event\t2\t2026-08-06T00:00:01Z\t1\tnormal\tnormal\toperator\tgeneration-complete\t-\t0\t0\tPASS' \
      $'event\t3\t2026-08-06T00:00:02Z\t0\t-\t-\tservice\tservice-ended\t-\t0\t0\tPASS' \
      $'event\t4\t2026-08-06T00:00:03Z\t0\t-\t-\tservice\tcleanup\t-\t0\t0\tPASS' \
      >> "$cleanup_inserted"
    if validate_request_session_cleanup_tail \
      "$cleanup_runtime" "$cleanup_inserted" "$self_test_root/unexpected-inserted-summary.tsv" \
      0123456789abcdef AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 1 \
      exact_cleanup_only 1 \
      >/dev/null 2>&1; then
      release_die "Synthetic cleanup evidence with an inserted event was accepted."
    fi
    printf '%s\n' \
      'stage=self-test' \
      'result=SELF_TEST_COMPLETE' \
      'lsof_parser_acceptance=1' \
      'lsof_parser_negative_cases=3' \
      'libproc_stable_samples=2' \
      'process_tuple_negative_cases=4' \
      'cleanup_tail_acceptance=1' \
      'cleanup_tail_negative_cases=5'
  )
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --report-directory) REPORT_DIRECTORY="${2:?--report-directory requires a value}"; shift 2 ;;
      --baseline-assets-directory) BASELINE_ASSETS_DIRECTORY="${2:?--baseline-assets-directory requires a value}"; shift 2 ;;
      --fixtures-root) FIXTURES_ROOT="${2:?--fixtures-root requires a value}"; shift 2 ;;
      --case) CASE_LABEL="${2:?--case requires a value}"; shift 2 ;;
      --request-evidence) REQUEST_EVIDENCE="${2:?--request-evidence requires a value}"; shift 2 ;;
      --request-generation) REQUEST_GENERATION="${2:?--request-generation requires a value}"; shift 2 ;;
      --app-generation) APP_GENERATION="${2:?--app-generation requires a value}"; shift 2 ;;
      --feed-transfer-mode) FEED_TRANSFER_MODE="${2:?--feed-transfer-mode requires a value}"; shift 2 ;;
      --app-log-evidence) APP_LOG_EVIDENCE="${2:?--app-log-evidence requires a value}"; shift 2 ;;
      --sparkle-log-evidence) SPARKLE_LOG_EVIDENCE="${2:?--sparkle-log-evidence requires a value}"; shift 2 ;;
      --operator-attestation) OPERATOR_ATTESTATION="${2:?--operator-attestation requires a value}"; shift 2 ;;
      --baseline-digest) EXPECTED_BASELINE_DIGEST="${2:?--baseline-digest requires a value}"; shift 2 ;;
      --runtime-digest) EXPECTED_RUNTIME_DIGEST="${2:?--runtime-digest requires a value}"; shift 2 ;;
      --controlled-digest) EXPECTED_CONTROLLED_DIGEST="${2:?--controlled-digest requires a value}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) release_die "Unknown argument: $1" ;;
    esac
  done
}

main() {
  local command="${1:-}"
  [[ -n "$command" ]] || { usage >&2; exit 1; }
  if [[ "$command" == "--help" || "$command" == "-h" ]]; then usage; return; fi
  shift
  parse_arguments "$@"
  require_non_root_user
  [[ "$FEED_TRANSFER_MODE" == "normal" || "$FEED_TRANSFER_MODE" == "chunked" ]] \
    || release_die "Feed transfer mode must be normal or chunked."
  [[ -z "$EXPECTED_BASELINE_DIGEST" || "$EXPECTED_BASELINE_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Baseline digest must be a lowercase SHA-256 value."
  [[ -z "$EXPECTED_RUNTIME_DIGEST" || "$EXPECTED_RUNTIME_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Runtime digest must be a lowercase SHA-256 value."
  [[ -z "$EXPECTED_CONTROLLED_DIGEST" || "$EXPECTED_CONTROLLED_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "Controlled digest must be a lowercase SHA-256 value."
  release_validate_update_rollout_constants
  for command_name in base64 codesign ditto find jq lsof log paste pgrep ruby sandbox-exec security shasum xattr xcrun xmllint; do
    release_require_command "$command_name"
  done
  case "$command" in
    prepare|baseline) prepare_baseline ;;
    negative-verify) verify_negative ;;
    finalize-negative) finalize_negative ;;
    success-verify) verify_success ;;
    finalize-success) finalize_success ;;
    self-test) run_self_test ;;
    *) usage >&2; release_die "Unknown transition evidence stage: $command" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
