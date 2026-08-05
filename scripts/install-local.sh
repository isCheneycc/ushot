#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

SOURCE_APP_INPUT="${1:-$PROJECT_ROOT/build/release/local-signed/artifacts/$USHOT_APP_BUNDLE}"
DESTINATION_APP="/Applications/$USHOT_APP_BUNDLE"
LEGACY_DESTINATION_APP="/Applications/$USHOT_LEGACY_APP_BUNDLE"
DESTINATION_EXECUTABLE="$DESTINATION_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME"
LEGACY_DESTINATION_EXECUTABLE="$LEGACY_DESTINATION_APP/Contents/MacOS/$USHOT_LEGACY_EXECUTABLE_NAME"
INSTALL_LOCK_DIR="/Applications/.Ushot-local-install.lock"

INSTALL_LOCK_FILE_ID=""
INSTALL_LOCK_HELD="NO"
STAGING_ROOT=""
STAGING_ROOT_FILE_ID=""
STAGED_APP=""
STAGED_FILE_ID=""
BACKUP_ROOT=""
BACKUP_ROOT_FILE_ID=""
CURRENT_BACKUP_APP=""
LEGACY_BACKUP_APP=""
FAILED_NEW_BACKUP_APP=""
CURRENT_ORIGINAL_FILE_ID=""
LEGACY_ORIGINAL_FILE_ID=""
CURRENT_ORIGINAL_EXECUTABLE_INODE=""
LEGACY_ORIGINAL_EXECUTABLE_INODE=""
CURRENT_ORIGINAL_REQUIREMENT=""
LEGACY_ORIGINAL_REQUIREMENT=""
STAGED_EXECUTABLE_INODE=""
CURRENT_WAS_RUNNING="NO"
LEGACY_WAS_RUNNING="NO"
PROCESS_SHUTDOWN_BEGAN="NO"
CURRENT_MOVE_BEGAN="NO"
LEGACY_MOVE_BEGAN="NO"
NEW_MOVE_BEGAN="NO"
CURRENT_MOVED="NO"
LEGACY_MOVED="NO"
NEW_INSTALLED="NO"
INSTALL_SUCCEEDED="NO"

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

require_real_app_directory() {
  local app_path="$1"
  local label="$2"
  [[ ! -L "$app_path" ]] || release_die "$label must not be a symbolic link: $app_path"
  [[ -d "$app_path" ]] || release_die "$label is not an app directory: $app_path"
}

release_file_id() {
  stat -f '%d:%i' "$1"
}

release_device_id() {
  stat -f '%d' "$1"
}

release_inode() {
  stat -f '%i' "$1"
}

release_team_identifier() {
  local app_path="$1"
  local details
  local team_identifier
  details="$(release_signature_details "$app_path")"
  team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"
  [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] \
    || release_die "Apple Development app has no TeamIdentifier: $app_path"
  printf '%s' "$team_identifier"
}

release_designated_requirement() {
  local app_path="$1"
  local requirement
  requirement="$(codesign --display --requirements - "$app_path" 2>&1 | sed -n 's/^designated => //p')"
  [[ -n "$requirement" ]] || release_die "App has no designated requirement: $app_path"
  printf '%s' "$requirement"
}

verify_legacy_apple_development_signature() {
  local app_path="$1"
  local expected_team="$2"
  local signing_requirement

  # The historical Xcode development build legitimately carries
  # get-task-allow. Migration accepts that legacy entitlement, but still
  # requires the Apple Development certificate extension and the exact Team
  # from the fully validated replacement. An Authority display string alone
  # is not an OS policy check, so enforce this as a designated requirement.
  [[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] \
    || release_die "Replacement has an unsafe TeamIdentifier: $expected_team"
  signing_requirement="identifier \"$USHOT_LEGACY_BUNDLE_IDENTIFIER\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.12] /* exists */ and certificate leaf[subject.OU] = \"$expected_team\""
  codesign --verify --deep --strict --verbose=2 "-R=$signing_requirement" "$app_path"
}

exact_executable_pids() {
  local executable_path="$1"
  local executable_pattern
  [[ "$executable_path" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || release_die "Refusing to inspect an unsafe executable path: $executable_path"
  executable_pattern="${executable_path//./[.]}"
  /usr/bin/pgrep -f "^${executable_pattern}([[:space:]].*)?$" 2>/dev/null || true
}

process_uses_executable_inode() {
  local pid="$1"
  local executable_path="$2"
  local expected_inode="$3"
  local lsof_output

  [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected_inode" =~ ^[1-9][0-9]*$ ]] || return 1
  lsof_output="$(/usr/sbin/lsof -a -p "$pid" -d txt -Ffin 2>/dev/null)" || return 1
  awk -v expected_path="$executable_path" -v expected_inode="$expected_inode" '
    /^f/ { inode = ""; next }
    /^i/ { inode = substr($0, 2); next }
    /^n/ {
      if (substr($0, 2) == expected_path && "x" inode == "x" expected_inode) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<<"$lsof_output"
}

all_pids_use_executable_inode() {
  local pids="$1"
  local executable_path="$2"
  local expected_inode="$3"
  local pid

  [[ -n "$pids" ]] || return 1
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    process_uses_executable_inode "$pid" "$executable_path" "$expected_inode" || return 1
  done <<<"$pids"
}

stop_exact_executable() {
  local executable_path="$1"
  local label="$2"
  local bundle_path="$3"
  local expected_bundle_file_id="$4"
  local expected_executable_inode="$5"
  local pids
  local pid
  local remaining
  local attempt

  pids="$(exact_executable_pids "$executable_path")"
  [[ -n "$pids" ]] || return 0
  [[ -n "$expected_bundle_file_id" \
      && "$(release_file_id "$bundle_path" 2>/dev/null || true)" == "$expected_bundle_file_id" ]] || {
    release_warn "Refusing to stop $label because its app bundle no longer has the validated identity: $bundle_path"
    return 1
  }
  all_pids_use_executable_inode "$pids" "$executable_path" "$expected_executable_inode" || {
    release_warn "Refusing to stop $label because an exact-path PID is not mapped to the validated executable inode."
    return 1
  }
  release_log "Stopping exact $label process path: $executable_path (PIDs: $(tr '\n' ' ' <<<"$pids" | sed 's/[[:space:]]*$//'))"

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
      release_warn "Refusing an invalid PID while stopping $label: $pid"
      return 1
    }
    kill -0 "$pid" 2>/dev/null || continue
    [[ "$(release_file_id "$bundle_path" 2>/dev/null || true)" == "$expected_bundle_file_id" ]] || {
      release_warn "Refusing to signal $label PID $pid because its app bundle changed."
      return 1
    }
    process_uses_executable_inode "$pid" "$executable_path" "$expected_executable_inode" || {
      release_warn "Refusing to signal $label PID $pid because it is not mapped to the validated executable inode."
      return 1
    }
    if ! kill -TERM "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
      release_warn "Could not send SIGTERM to exact $label PID $pid"
      return 1
    fi
  done <<<"$pids"

  for ((attempt = 1; attempt <= 40; attempt += 1)); do
    remaining="$(exact_executable_pids "$executable_path")"
    [[ -z "$remaining" ]] && return 0
    sleep 0.25
  done

  release_warn "$label did not quit after SIGTERM; remaining exact-path PIDs: $(tr '\n' ' ' <<<"$remaining" | sed 's/[[:space:]]*$//')"
  return 1
}

wait_for_exact_executable() {
  local executable_path="$1"
  local expected_executable_inode="$2"
  local pids=""
  local attempt

  for ((attempt = 1; attempt <= 20; attempt += 1)); do
    pids="$(exact_executable_pids "$executable_path")"
    if [[ -n "$pids" ]] \
        && all_pids_use_executable_inode "$pids" "$executable_path" "$expected_executable_inode"; then
      break
    fi
    sleep 0.25
  done
  [[ -n "$pids" ]] || return 1

  # Do not accept a process that appears only briefly and exits immediately.
  sleep 1
  pids="$(exact_executable_pids "$executable_path")"
  [[ -n "$pids" ]] || return 1
  all_pids_use_executable_inode "$pids" "$executable_path" "$expected_executable_inode" || return 1
  printf '%s' "$pids"
}

launch_exact_app() {
  local app_path="$1"
  local executable_path="$2"
  local label="$3"
  local executable_inode
  local pids

  [[ -x "$executable_path" && ! -L "$executable_path" ]] || return 1
  executable_inode="$(release_inode "$executable_path")" || return 1
  [[ -z "$(exact_executable_pids "$executable_path")" ]] || {
    release_warn "Refusing to launch $label because an exact-path process already exists."
    return 1
  }
  /usr/bin/open -na "$app_path" || return 1
  pids="$(wait_for_exact_executable "$executable_path" "$executable_inode")" || return 1
  release_log "$label is running from its exact installed path (PIDs: $(tr '\n' ' ' <<<"$pids" | sed 's/[[:space:]]*$//'))"
}

validate_current_local_app() {
  local app_path="$1"
  local expected_team="$2"
  local source_requirement="$3"
  local info_plist="$app_path/Contents/Info.plist"
  local version
  local build_number
  local installed_team
  local installed_requirement

  require_real_app_directory "$app_path" "Installed Ushot"
  version="$(release_plist_value "$info_plist" CFBundleShortVersionString)"
  build_number="$(release_plist_value "$info_plist" CFBundleVersion)"
  release_validate_version "$version"
  release_validate_build_number "$build_number"
  release_validate_supported_installed_app_identity "$app_path" "$version" "$build_number"
  release_verify_signature_mode "$app_path" local-signed

  installed_team="$(release_team_identifier "$app_path")"
  [[ "$installed_team" == "$expected_team" ]] \
    || release_die "Installed Ushot TeamIdentifier does not match the replacement: installed=$installed_team source=$expected_team"
  installed_requirement="$(release_designated_requirement "$app_path")"
  codesign --verify --strict "-R=$installed_requirement" "$SOURCE_APP" >/dev/null 2>&1 \
    || release_die "Replacement Ushot does not satisfy the installed designated requirement."
  codesign --verify --strict "-R=$source_requirement" "$app_path" >/dev/null 2>&1 \
    || release_die "Installed Ushot does not satisfy the replacement designated requirement."
}

validate_current_recovery_app() {
  local app_path="$1"
  local expected_team="$2"
  local expected_requirement="$3"
  local info_plist="$app_path/Contents/Info.plist"
  local version
  local build_number
  local installed_team
  local installed_requirement

  require_real_app_directory "$app_path" "Recoverable Ushot backup"
  version="$(release_plist_value "$info_plist" CFBundleShortVersionString)"
  build_number="$(release_plist_value "$info_plist" CFBundleVersion)"
  release_validate_version "$version"
  release_validate_build_number "$build_number"
  release_validate_supported_installed_app_identity "$app_path" "$version" "$build_number"
  release_verify_signature_mode "$app_path" local-signed
  installed_team="$(release_team_identifier "$app_path")"
  [[ "$installed_team" == "$expected_team" ]] \
    || release_die "Recoverable Ushot backup has an unexpected TeamIdentifier."
  installed_requirement="$(release_designated_requirement "$app_path")"
  [[ "$installed_requirement" == "$expected_requirement" ]] \
    || release_die "Recoverable Ushot backup has an unexpected designated requirement."
}

validate_legacy_local_app() {
  local app_path="$1"
  local expected_team="$2"
  local info_plist="$app_path/Contents/Info.plist"
  local version
  local build_number
  local installed_team

  require_real_app_directory "$app_path" "Legacy Ushot"
  [[ "$(basename "$app_path")" == "$USHOT_LEGACY_APP_BUNDLE" ]] \
    || release_die "Legacy app must use the exact bundle name $USHOT_LEGACY_APP_BUNDLE."
  [[ -f "$info_plist" ]] || release_die "Legacy app Info.plist is missing: $info_plist"
  [[ "$(release_plist_value "$info_plist" CFBundleIdentifier)" == "$USHOT_LEGACY_BUNDLE_IDENTIFIER" ]] \
    || release_die "Refusing an unknown app at $app_path: unexpected legacy bundle identifier."
  [[ "$(release_plist_value "$info_plist" CFBundleExecutable)" == "$USHOT_LEGACY_EXECUTABLE_NAME" ]] \
    || release_die "Refusing an unknown app at $app_path: unexpected legacy executable."
  [[ -x "$app_path/Contents/MacOS/$USHOT_LEGACY_EXECUTABLE_NAME" ]] \
    || release_die "Legacy executable is missing or not executable: $app_path"
  version="$(release_plist_value "$info_plist" CFBundleShortVersionString)"
  build_number="$(release_plist_value "$info_plist" CFBundleVersion)"
  release_validate_version "$version"
  release_validate_build_number "$build_number"
  verify_legacy_apple_development_signature "$app_path" "$expected_team"
  release_designated_requirement "$app_path" >/dev/null

  installed_team="$(release_team_identifier "$app_path")"
  [[ "$installed_team" == "$expected_team" ]] \
    || release_die "Legacy Ushot TeamIdentifier does not match the replacement: legacy=$installed_team source=$expected_team"
}

validate_staged_copy() {
  local app_path="$1"
  local expected_version="$2"
  local expected_build="$3"
  local expected_team="$4"
  local expected_requirement="$5"
  local staged_team
  local staged_requirement

  release_validate_app_identity "$app_path" "$expected_version" "$expected_build"
  release_verify_signature_mode "$app_path" local-signed
  staged_team="$(release_team_identifier "$app_path")"
  [[ "$staged_team" == "$expected_team" ]] \
    || release_die "Staged Ushot TeamIdentifier changed during copy."
  staged_requirement="$(release_designated_requirement "$app_path")"
  [[ "$staged_requirement" == "$expected_requirement" ]] \
    || release_die "Staged Ushot designated requirement changed during copy."
  /usr/bin/diff -qr --no-dereference "$SOURCE_APP" "$app_path" >/dev/null \
    || release_die "Staged Ushot bundle is not byte-for-byte equivalent to the source bundle."
}

validate_replacement_recovery_app() {
  local app_path="$1"
  local expected_version="$2"
  local expected_build="$3"
  local expected_team="$4"
  local expected_requirement="$5"
  local expected_binary_sha="$6"

  require_real_app_directory "$app_path" "Installed replacement Ushot"
  release_validate_app_identity "$app_path" "$expected_version" "$expected_build"
  release_verify_signature_mode "$app_path" local-signed
  [[ "$(release_team_identifier "$app_path")" == "$expected_team" ]] \
    || release_die "Installed replacement TeamIdentifier changed."
  [[ "$(release_designated_requirement "$app_path")" == "$expected_requirement" ]] \
    || release_die "Installed replacement designated requirement changed."
  [[ "$(release_sha256 "$app_path/Contents/MacOS/$USHOT_EXECUTABLE_NAME")" == "$expected_binary_sha" ]] \
    || release_die "Installed replacement executable hash changed."
}

acquire_install_lock() {
  # mkdir is the cross-process transaction boundary. Signals are ignored only
  # across this tiny acquisition window so an acquired lock is never left
  # ownerless before its inode can be recorded.
  trap '' HUP INT TERM
  if ! /bin/mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    trap 'handle_signal HUP 129' HUP
    trap 'handle_signal INT 130' INT
    trap 'handle_signal TERM 143' TERM
    release_die "Another local Ushot installation may be active. If no installer is running, inspect and remove the stale empty lock directory manually: $INSTALL_LOCK_DIR"
  fi
  INSTALL_LOCK_HELD="YES"
  INSTALL_LOCK_FILE_ID="$(release_file_id "$INSTALL_LOCK_DIR")"
  trap 'handle_signal HUP 129' HUP
  trap 'handle_signal INT 130' INT
  trap 'handle_signal TERM 143' TERM
  release_log "Acquired exclusive local-install lock: $INSTALL_LOCK_DIR"
}

release_install_lock() {
  [[ "$INSTALL_LOCK_HELD" == "YES" ]] || return 0
  if [[ ! -d "$INSTALL_LOCK_DIR" || -L "$INSTALL_LOCK_DIR" ]]; then
    release_warn "Install lock path changed or disappeared; refusing lock cleanup: $INSTALL_LOCK_DIR"
    return 1
  fi
  if [[ -z "$INSTALL_LOCK_FILE_ID" \
      || "$(release_file_id "$INSTALL_LOCK_DIR" 2>/dev/null || true)" != "$INSTALL_LOCK_FILE_ID" ]]; then
    release_warn "Install lock identity changed; refusing lock cleanup: $INSTALL_LOCK_DIR"
    return 1
  fi
  if ! /bin/rmdir "$INSTALL_LOCK_DIR"; then
    release_warn "Could not remove the validated empty install lock: $INSTALL_LOCK_DIR"
    return 1
  fi
  INSTALL_LOCK_HELD="NO"
  INSTALL_LOCK_FILE_ID=""
}

cleanup_staging_root() {
  [[ -n "$STAGING_ROOT" ]] || return 0
  case "$STAGING_ROOT" in
    /Applications/.Ushot-local-install.*) ;;
    *)
      release_warn "Refusing to clean an unexpected staging path: $STAGING_ROOT"
      return 1
      ;;
  esac
  if [[ -d "$STAGING_ROOT" ]]; then
    if [[ -z "$STAGING_ROOT_FILE_ID" \
        || "$(release_file_id "$STAGING_ROOT" 2>/dev/null || true)" != "$STAGING_ROOT_FILE_ID" ]]; then
      release_warn "Refusing to clean a staging directory whose identity changed: $STAGING_ROOT"
      return 1
    fi
    if ! /bin/rm -rf "$STAGING_ROOT"; then
      release_warn "Could not remove the validated staging directory: $STAGING_ROOT"
      return 1
    fi
    if path_exists "$STAGING_ROOT"; then
      release_warn "Staging directory still exists after cleanup: $STAGING_ROOT"
      return 1
    fi
  fi
  STAGING_ROOT=""
  STAGING_ROOT_FILE_ID=""
  STAGED_APP=""
}

cleanup_empty_backup_root() {
  [[ -n "$BACKUP_ROOT" && -d "$BACKUP_ROOT" ]] || return 0
  if [[ -z "$BACKUP_ROOT_FILE_ID" \
      || "$(release_file_id "$BACKUP_ROOT" 2>/dev/null || true)" != "$BACKUP_ROOT_FILE_ID" ]]; then
    release_warn "Refusing to remove a backup directory whose identity changed: $BACKUP_ROOT"
    return 1
  fi
  if /bin/rmdir "$BACKUP_ROOT" 2>/dev/null; then
    return 0
  fi
  if [[ -n "$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    # A nonempty backup root is the intended successful or failed recovery
    # location and must remain in Trash.
    return 0
  fi
  release_warn "Could not remove the empty backup directory: $BACKUP_ROOT"
  return 1
}

restart_previous_app_if_needed() {
  local was_running="$1"
  local app_path="$2"
  local executable_path="$3"
  local label="$4"
  local expected_executable_inode="$5"
  local existing_pids

  [[ "$was_running" == "YES" ]] || return 0
  existing_pids="$(exact_executable_pids "$executable_path")"
  if [[ -n "$existing_pids" ]]; then
    all_pids_use_executable_inode "$existing_pids" "$executable_path" "$expected_executable_inode" || {
      release_warn "An exact-path $label PID is not the restored executable; refusing to launch another instance."
      return 1
    }
    sleep 1
    existing_pids="$(exact_executable_pids "$executable_path")"
    if [[ -n "$existing_pids" ]]; then
      all_pids_use_executable_inode "$existing_pids" "$executable_path" "$expected_executable_inode" || return 1
      release_log "$label was already running and remained stable after rollback."
      return 0
    fi
  fi
  [[ -d "$app_path" && ! -L "$app_path" ]] || {
    release_warn "Cannot restart the previously running $label because its installed path was not restored: $app_path"
    return 1
  }
  launch_exact_app "$app_path" "$executable_path" "Restored $label"
}

rollback_install() {
  local rollback_failed="NO"
  local destination_file_id=""
  local replacement_stopped="YES"

  release_warn "Local Ushot installation failed; starting rollback."

  # Reconcile the three atomic renames in case the shell was interrupted after
  # rename(2) completed but before its in-memory state flag was assigned.
  if [[ "$CURRENT_MOVE_BEGAN" == "YES" && "$CURRENT_MOVED" != "YES" ]]; then
    if [[ "$(release_file_id "$CURRENT_BACKUP_APP" 2>/dev/null || true)" == "$CURRENT_ORIGINAL_FILE_ID" \
        && ! -e "$DESTINATION_APP" && ! -L "$DESTINATION_APP" ]]; then
      CURRENT_MOVED="YES"
    elif [[ "$(release_file_id "$DESTINATION_APP" 2>/dev/null || true)" != "$CURRENT_ORIGINAL_FILE_ID" ]]; then
      release_warn "Could not reconcile the interrupted current-Ushot backup move."
      rollback_failed="YES"
    fi
  fi
  if [[ "$LEGACY_MOVE_BEGAN" == "YES" && "$LEGACY_MOVED" != "YES" ]]; then
    if [[ "$(release_file_id "$LEGACY_BACKUP_APP" 2>/dev/null || true)" == "$LEGACY_ORIGINAL_FILE_ID" \
        && ! -e "$LEGACY_DESTINATION_APP" && ! -L "$LEGACY_DESTINATION_APP" ]]; then
      LEGACY_MOVED="YES"
    elif [[ "$(release_file_id "$LEGACY_DESTINATION_APP" 2>/dev/null || true)" != "$LEGACY_ORIGINAL_FILE_ID" ]]; then
      release_warn "Could not reconcile the interrupted legacy-UshotApp backup move."
      rollback_failed="YES"
    fi
  fi
  if [[ "$NEW_MOVE_BEGAN" == "YES" && "$NEW_INSTALLED" != "YES" ]]; then
    if [[ "$(release_file_id "$DESTINATION_APP" 2>/dev/null || true)" == "$STAGED_FILE_ID" ]]; then
      NEW_INSTALLED="YES"
    elif [[ "$(release_file_id "$STAGED_APP" 2>/dev/null || true)" != "$STAGED_FILE_ID" ]]; then
      release_warn "Could not reconcile the interrupted staged-Ushot install rename."
      rollback_failed="YES"
    fi
  fi

  if [[ "$NEW_INSTALLED" == "YES" ]]; then
    if path_exists "$DESTINATION_APP"; then
      destination_file_id="$(release_file_id "$DESTINATION_APP" 2>/dev/null || true)"
      if [[ -z "$STAGED_FILE_ID" || "$destination_file_id" != "$STAGED_FILE_ID" ]]; then
        release_warn "Refusing to signal an unrecognized app at the current destination during rollback: $DESTINATION_APP"
        replacement_stopped="NO"
      elif [[ "$(release_inode "$DESTINATION_EXECUTABLE" 2>/dev/null || true)" != "$STAGED_EXECUTABLE_INODE" ]] \
          || ! (validate_replacement_recovery_app \
            "$DESTINATION_APP" \
            "$SOURCE_VERSION" \
            "$SOURCE_BUILD" \
            "$SOURCE_TEAM" \
            "$SOURCE_REQUIREMENT" \
            "$SOURCE_BINARY_SHA"); then
        release_warn "Refusing to signal a replacement whose validated executable identity changed."
        replacement_stopped="NO"
      else
        stop_exact_executable \
          "$DESTINATION_EXECUTABLE" \
          "failed replacement Ushot" \
          "$DESTINATION_APP" \
          "$STAGED_FILE_ID" \
          "$STAGED_EXECUTABLE_INODE" \
          || replacement_stopped="NO"
      fi
    fi
    if [[ "$replacement_stopped" != "YES" ]]; then
      rollback_failed="YES"
      release_warn "Refusing to move the failed replacement because its identity or process ownership is uncertain."
    fi
    if path_exists "$DESTINATION_APP"; then
      destination_file_id="$(release_file_id "$DESTINATION_APP" 2>/dev/null || true)"
      if [[ "$replacement_stopped" != "YES" ]]; then
        :
      elif [[ -n "$STAGED_FILE_ID" \
          && "$destination_file_id" == "$STAGED_FILE_ID" \
          && "$(release_inode "$DESTINATION_EXECUTABLE" 2>/dev/null || true)" == "$STAGED_EXECUTABLE_INODE" ]] \
          && (validate_replacement_recovery_app \
            "$DESTINATION_APP" \
            "$SOURCE_VERSION" \
            "$SOURCE_BUILD" \
            "$SOURCE_TEAM" \
            "$SOURCE_REQUIREMENT" \
            "$SOURCE_BINARY_SHA"); then
        FAILED_NEW_BACKUP_APP="$BACKUP_ROOT/Ushot-failed-install.app"
        if [[ "$(release_file_id "$BACKUP_ROOT" 2>/dev/null || true)" != "$BACKUP_ROOT_FILE_ID" ]]; then
          release_warn "Backup directory identity changed; refusing to move the failed replacement: $BACKUP_ROOT"
          rollback_failed="YES"
        elif path_exists "$FAILED_NEW_BACKUP_APP"; then
          release_warn "Cannot preserve failed replacement because the recovery path already exists: $FAILED_NEW_BACKUP_APP"
          rollback_failed="YES"
        elif /bin/mv "$DESTINATION_APP" "$FAILED_NEW_BACKUP_APP"; then
          if [[ "$(release_file_id "$FAILED_NEW_BACKUP_APP" 2>/dev/null || true)" == "$STAGED_FILE_ID" ]]; then
            release_warn "Failed replacement preserved at: $FAILED_NEW_BACKUP_APP"
            NEW_INSTALLED="NO"
          else
            release_warn "Failed replacement move did not preserve its validated directory identity: $FAILED_NEW_BACKUP_APP"
            rollback_failed="YES"
          fi
        else
          release_warn "Could not move the failed replacement to Trash: $DESTINATION_APP"
          rollback_failed="YES"
        fi
      else
        release_warn "Refusing to move an unrecognized app from the current destination during rollback: $DESTINATION_APP"
        rollback_failed="YES"
      fi
    fi
  fi

  if [[ "$CURRENT_MOVED" == "YES" ]]; then
    if path_exists "$DESTINATION_APP"; then
      release_warn "Cannot restore the previous Ushot because the destination is occupied: $DESTINATION_APP"
      rollback_failed="YES"
    elif [[ "$(release_file_id "$CURRENT_BACKUP_APP" 2>/dev/null || true)" != "$CURRENT_ORIGINAL_FILE_ID" ]]; then
      release_warn "Current Ushot backup identity changed; refusing rollback move: $CURRENT_BACKUP_APP"
      rollback_failed="YES"
    elif [[ "$(release_inode "$CURRENT_BACKUP_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME" 2>/dev/null || true)" != "$CURRENT_ORIGINAL_EXECUTABLE_INODE" ]] \
        || ! (validate_current_recovery_app "$CURRENT_BACKUP_APP" "$SOURCE_TEAM" "$CURRENT_ORIGINAL_REQUIREMENT"); then
      release_warn "Current Ushot backup no longer passes the validated identity/signature checks: $CURRENT_BACKUP_APP"
      rollback_failed="YES"
    elif /bin/mv "$CURRENT_BACKUP_APP" "$DESTINATION_APP"; then
      CURRENT_MOVED="NO"
      if [[ "$(release_file_id "$DESTINATION_APP" 2>/dev/null || true)" == "$CURRENT_ORIGINAL_FILE_ID" \
          && "$(release_inode "$DESTINATION_EXECUTABLE" 2>/dev/null || true)" == "$CURRENT_ORIGINAL_EXECUTABLE_INODE" ]] \
          && (validate_current_recovery_app "$DESTINATION_APP" "$SOURCE_TEAM" "$CURRENT_ORIGINAL_REQUIREMENT"); then
        release_warn "Restored previous Ushot to: $DESTINATION_APP"
      else
        release_warn "Previous Ushot was moved back but failed post-restore validation: $DESTINATION_APP"
        rollback_failed="YES"
      fi
    else
      release_warn "Could not restore previous Ushot from: $CURRENT_BACKUP_APP"
      rollback_failed="YES"
    fi
  fi

  if [[ "$LEGACY_MOVED" == "YES" ]]; then
    if path_exists "$LEGACY_DESTINATION_APP"; then
      release_warn "Cannot restore legacy Ushot because the destination is occupied: $LEGACY_DESTINATION_APP"
      rollback_failed="YES"
    elif [[ "$(release_file_id "$LEGACY_BACKUP_APP" 2>/dev/null || true)" != "$LEGACY_ORIGINAL_FILE_ID" ]]; then
      release_warn "Legacy Ushot backup identity changed; refusing rollback move: $LEGACY_BACKUP_APP"
      rollback_failed="YES"
    elif [[ "$(release_inode "$LEGACY_BACKUP_APP/Contents/MacOS/$USHOT_LEGACY_EXECUTABLE_NAME" 2>/dev/null || true)" != "$LEGACY_ORIGINAL_EXECUTABLE_INODE" ]] \
        || ! (validate_legacy_local_app "$LEGACY_BACKUP_APP" "$SOURCE_TEAM") \
        || [[ "$(release_designated_requirement "$LEGACY_BACKUP_APP" 2>/dev/null || true)" != "$LEGACY_ORIGINAL_REQUIREMENT" ]]; then
      release_warn "Legacy UshotApp backup no longer passes the validated identity/signature checks: $LEGACY_BACKUP_APP"
      rollback_failed="YES"
    elif /bin/mv "$LEGACY_BACKUP_APP" "$LEGACY_DESTINATION_APP"; then
      LEGACY_MOVED="NO"
      if [[ "$(release_file_id "$LEGACY_DESTINATION_APP" 2>/dev/null || true)" == "$LEGACY_ORIGINAL_FILE_ID" \
          && "$(release_inode "$LEGACY_DESTINATION_EXECUTABLE" 2>/dev/null || true)" == "$LEGACY_ORIGINAL_EXECUTABLE_INODE" ]] \
          && (validate_legacy_local_app "$LEGACY_DESTINATION_APP" "$SOURCE_TEAM") \
          && [[ "$(release_designated_requirement "$LEGACY_DESTINATION_APP" 2>/dev/null || true)" == "$LEGACY_ORIGINAL_REQUIREMENT" ]]; then
        release_warn "Restored legacy Ushot to: $LEGACY_DESTINATION_APP"
      else
        release_warn "Legacy UshotApp was moved back but failed post-restore validation: $LEGACY_DESTINATION_APP"
        rollback_failed="YES"
      fi
    else
      release_warn "Could not restore legacy Ushot from: $LEGACY_BACKUP_APP"
      rollback_failed="YES"
    fi
  fi

  if [[ "$PROCESS_SHUTDOWN_BEGAN" == "YES" ]]; then
    restart_previous_app_if_needed \
      "$CURRENT_WAS_RUNNING" \
      "$DESTINATION_APP" \
      "$DESTINATION_EXECUTABLE" \
      "Ushot" \
      "$CURRENT_ORIGINAL_EXECUTABLE_INODE" \
      || rollback_failed="YES"
    restart_previous_app_if_needed \
      "$LEGACY_WAS_RUNNING" \
      "$LEGACY_DESTINATION_APP" \
      "$LEGACY_DESTINATION_EXECUTABLE" \
      "legacy UshotApp" \
      "$LEGACY_ORIGINAL_EXECUTABLE_INODE" \
      || rollback_failed="YES"
  fi

  cleanup_staging_root || rollback_failed="YES"
  cleanup_empty_backup_root || rollback_failed="YES"
  release_install_lock || rollback_failed="YES"

  if [[ "$CURRENT_MOVED" == "YES" ]]; then
    release_warn "Manual recovery path for previous Ushot: $CURRENT_BACKUP_APP"
  fi
  if [[ "$LEGACY_MOVED" == "YES" ]]; then
    release_warn "Manual recovery path for legacy UshotApp: $LEGACY_BACKUP_APP"
  fi
  if [[ -n "$FAILED_NEW_BACKUP_APP" && -e "$FAILED_NEW_BACKUP_APP" ]]; then
    release_warn "Failed replacement recovery path: $FAILED_NEW_BACKUP_APP"
  fi
  [[ "$rollback_failed" == "NO" ]]
}

handle_exit() {
  local exit_status="$1"
  local rollback_status=0
  trap - EXIT
  trap '' HUP INT TERM
  set +e

  if [[ "$INSTALL_SUCCEEDED" == "YES" ]]; then
    release_install_lock \
      || release_warn "Installation succeeded, but the local-install lock requires manual inspection: $INSTALL_LOCK_DIR"
    exit "$exit_status"
  fi
  if [[ "$exit_status" -eq 0 ]]; then
    exit_status=1
  fi
  rollback_install || rollback_status=$?
  if [[ "$rollback_status" -ne 0 ]]; then
    release_warn "Rollback was incomplete; use the recovery paths above and inspect /Applications before retrying."
  fi
  exit "$exit_status"
}

handle_signal() {
  local signal_name="$1"
  local signal_status="$2"
  release_warn "Received $signal_name during local installation; rolling back before exit."
  exit "$signal_status"
}

install_local_main() {
trap 'handle_exit $?' EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

release_require_command codesign
release_require_command ditto
release_require_command file
release_require_command pgrep
release_require_command open
release_require_command diff
release_require_command mktemp
release_require_command find
release_require_command stat
release_require_command shasum
release_require_command lsof

require_real_app_directory "$SOURCE_APP_INPUT" "Signed source app"
SOURCE_APP="$(cd "$(dirname "$SOURCE_APP_INPUT")" && pwd -P)/$(basename "$SOURCE_APP_INPUT")"
[[ "$SOURCE_APP" != "$DESTINATION_APP" && "$SOURCE_APP" != "$LEGACY_DESTINATION_APP" ]] \
  || release_die "The source app must be a build artifact outside the installed application paths."

SOURCE_INFO="$SOURCE_APP/Contents/Info.plist"
SOURCE_VERSION="$(release_plist_value "$SOURCE_INFO" CFBundleShortVersionString)"
SOURCE_BUILD="$(release_plist_value "$SOURCE_INFO" CFBundleVersion)"
release_validate_version "$SOURCE_VERSION"
release_validate_build_number "$SOURCE_BUILD"
release_validate_app_identity "$SOURCE_APP" "$SOURCE_VERSION" "$SOURCE_BUILD"
release_verify_signature_mode "$SOURCE_APP" local-signed

SOURCE_TEAM="$(release_team_identifier "$SOURCE_APP")"
SOURCE_REQUIREMENT="$(release_designated_requirement "$SOURCE_APP")"
SOURCE_BINARY_SHA="$(release_sha256 "$SOURCE_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME")"

acquire_install_lock

if path_exists "$DESTINATION_APP"; then
  validate_current_local_app "$DESTINATION_APP" "$SOURCE_TEAM" "$SOURCE_REQUIREMENT"
  CURRENT_ORIGINAL_FILE_ID="$(release_file_id "$DESTINATION_APP")"
  CURRENT_ORIGINAL_EXECUTABLE_INODE="$(release_inode "$DESTINATION_EXECUTABLE")"
  CURRENT_ORIGINAL_REQUIREMENT="$(release_designated_requirement "$DESTINATION_APP")"
fi
if path_exists "$LEGACY_DESTINATION_APP"; then
  validate_legacy_local_app "$LEGACY_DESTINATION_APP" "$SOURCE_TEAM"
  LEGACY_ORIGINAL_FILE_ID="$(release_file_id "$LEGACY_DESTINATION_APP")"
  LEGACY_ORIGINAL_EXECUTABLE_INODE="$(release_inode "$LEGACY_DESTINATION_EXECUTABLE")"
  LEGACY_ORIGINAL_REQUIREMENT="$(release_designated_requirement "$LEGACY_DESTINATION_APP")"
fi

APPLICATIONS_DEVICE="$(release_device_id /Applications)"
STAGING_ROOT="$(/usr/bin/mktemp -d /Applications/.Ushot-local-install.XXXXXX)"
STAGING_ROOT_FILE_ID="$(release_file_id "$STAGING_ROOT")"
[[ "$(release_device_id "$STAGING_ROOT")" == "$APPLICATIONS_DEVICE" ]] \
  || release_die "Ushot staging directory is not on the /Applications volume."
STAGED_APP="$STAGING_ROOT/$USHOT_APP_BUNDLE"
/usr/bin/ditto --rsrc --extattr "$SOURCE_APP" "$STAGED_APP"
validate_staged_copy \
  "$STAGED_APP" \
  "$SOURCE_VERSION" \
  "$SOURCE_BUILD" \
  "$SOURCE_TEAM" \
  "$SOURCE_REQUIREMENT"
STAGED_FILE_ID="$(release_file_id "$STAGED_APP")"
STAGED_EXECUTABLE_INODE="$(release_inode "$STAGED_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME")"

[[ -d "$HOME/.Trash" && ! -L "$HOME/.Trash" ]] \
  || release_die "The user's Trash directory is unavailable or unsafe: $HOME/.Trash"
[[ "$(release_device_id "$HOME/.Trash")" == "$APPLICATIONS_DEVICE" ]] \
  || release_die "The user's Trash and /Applications must be on the same volume for atomic recovery moves."
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_ROOT="$(/usr/bin/mktemp -d "$HOME/.Trash/Ushot-local-install-backup-$TIMESTAMP.XXXXXX")"
BACKUP_ROOT_FILE_ID="$(release_file_id "$BACKUP_ROOT")"
CURRENT_BACKUP_APP="$BACKUP_ROOT/$USHOT_APP_BUNDLE"
LEGACY_BACKUP_APP="$BACKUP_ROOT/$USHOT_LEGACY_APP_BUNDLE"

# Immediately re-establish each bundle and executable identity before looking
# up or signalling an exact-path PID. If an app appeared, disappeared or was
# replaced during staging, fail without terminating it.
if [[ -n "$CURRENT_ORIGINAL_FILE_ID" ]]; then
  path_exists "$DESTINATION_APP" \
    || release_die "Installed Ushot disappeared before process shutdown."
  validate_current_local_app "$DESTINATION_APP" "$SOURCE_TEAM" "$SOURCE_REQUIREMENT"
  [[ "$(release_file_id "$DESTINATION_APP")" == "$CURRENT_ORIGINAL_FILE_ID" \
      && "$(release_inode "$DESTINATION_EXECUTABLE")" == "$CURRENT_ORIGINAL_EXECUTABLE_INODE" ]] \
    || release_die "Installed Ushot changed before process shutdown; refusing to signal it."
elif path_exists "$DESTINATION_APP"; then
  release_die "An unvalidated app appeared at $DESTINATION_APP; refusing to signal it."
fi
if [[ -n "$LEGACY_ORIGINAL_FILE_ID" ]]; then
  path_exists "$LEGACY_DESTINATION_APP" \
    || release_die "Legacy UshotApp disappeared before process shutdown."
  validate_legacy_local_app "$LEGACY_DESTINATION_APP" "$SOURCE_TEAM"
  [[ "$(release_file_id "$LEGACY_DESTINATION_APP")" == "$LEGACY_ORIGINAL_FILE_ID" \
      && "$(release_inode "$LEGACY_DESTINATION_EXECUTABLE")" == "$LEGACY_ORIGINAL_EXECUTABLE_INODE" \
      && "$(release_designated_requirement "$LEGACY_DESTINATION_APP")" == "$LEGACY_ORIGINAL_REQUIREMENT" ]] \
    || release_die "Legacy UshotApp changed before process shutdown; refusing to signal it."
elif path_exists "$LEGACY_DESTINATION_APP"; then
  release_die "An unvalidated app appeared at $LEGACY_DESTINATION_APP; refusing to signal it."
fi

CURRENT_RUNNING_PIDS="$(exact_executable_pids "$DESTINATION_EXECUTABLE")"
LEGACY_RUNNING_PIDS="$(exact_executable_pids "$LEGACY_DESTINATION_EXECUTABLE")"
if [[ -n "$CURRENT_RUNNING_PIDS" ]]; then
  path_exists "$DESTINATION_APP" \
    || release_die "Refusing to terminate a current-path process whose app bundle is unavailable for identity validation."
  CURRENT_WAS_RUNNING="YES"
fi
if [[ -n "$LEGACY_RUNNING_PIDS" ]]; then
  path_exists "$LEGACY_DESTINATION_APP" \
    || release_die "Refusing to terminate a legacy-path process whose app bundle is unavailable for identity validation."
  LEGACY_WAS_RUNNING="YES"
fi

PROCESS_SHUTDOWN_BEGAN="YES"
stop_exact_executable \
  "$DESTINATION_EXECUTABLE" \
  "current Ushot" \
  "$DESTINATION_APP" \
  "$CURRENT_ORIGINAL_FILE_ID" \
  "$CURRENT_ORIGINAL_EXECUTABLE_INODE" \
  || release_die "Current Ushot did not terminate cleanly; installation was not started."
stop_exact_executable \
  "$LEGACY_DESTINATION_EXECUTABLE" \
  "legacy UshotApp" \
  "$LEGACY_DESTINATION_APP" \
  "$LEGACY_ORIGINAL_FILE_ID" \
  "$LEGACY_ORIGINAL_EXECUTABLE_INODE" \
  || release_die "Legacy UshotApp did not terminate cleanly; installation was not started."

# Revalidate the staged source after process shutdown and immediately before
# moving either installed app. No installed state changes before this point.
validate_staged_copy \
  "$STAGED_APP" \
  "$SOURCE_VERSION" \
  "$SOURCE_BUILD" \
  "$SOURCE_TEAM" \
  "$SOURCE_REQUIREMENT"

# Revalidate both known installed identities after they are stopped. This
# closes the staging-time window in which an in-place mutation could otherwise
# retain the same directory inode and reach the backup transaction.
if [[ -n "$CURRENT_ORIGINAL_FILE_ID" ]] && ! path_exists "$DESTINATION_APP"; then
  release_die "Installed Ushot disappeared after validation; refusing to continue."
fi
if [[ -n "$LEGACY_ORIGINAL_FILE_ID" ]] && ! path_exists "$LEGACY_DESTINATION_APP"; then
  release_die "Legacy UshotApp disappeared after validation; refusing to continue."
fi
if path_exists "$DESTINATION_APP"; then
  [[ "$(release_file_id "$BACKUP_ROOT")" == "$BACKUP_ROOT_FILE_ID" ]] \
    || release_die "Backup directory identity changed before moving current Ushot."
  ! path_exists "$CURRENT_BACKUP_APP" \
    || release_die "Current Ushot recovery path became occupied: $CURRENT_BACKUP_APP"
  validate_current_local_app "$DESTINATION_APP" "$SOURCE_TEAM" "$SOURCE_REQUIREMENT"
  [[ "$(release_file_id "$DESTINATION_APP")" == "$CURRENT_ORIGINAL_FILE_ID" \
      && "$(release_inode "$DESTINATION_EXECUTABLE")" == "$CURRENT_ORIGINAL_EXECUTABLE_INODE" ]] \
    || release_die "Installed Ushot changed after its initial validation."
fi
if path_exists "$LEGACY_DESTINATION_APP"; then
  [[ "$(release_file_id "$BACKUP_ROOT")" == "$BACKUP_ROOT_FILE_ID" ]] \
    || release_die "Backup directory identity changed before moving legacy UshotApp."
  ! path_exists "$LEGACY_BACKUP_APP" \
    || release_die "Legacy UshotApp recovery path became occupied: $LEGACY_BACKUP_APP"
  validate_legacy_local_app "$LEGACY_DESTINATION_APP" "$SOURCE_TEAM"
  [[ "$(release_file_id "$LEGACY_DESTINATION_APP")" == "$LEGACY_ORIGINAL_FILE_ID" \
      && "$(release_inode "$LEGACY_DESTINATION_EXECUTABLE")" == "$LEGACY_ORIGINAL_EXECUTABLE_INODE" ]] \
    || release_die "Legacy UshotApp changed after its initial validation."
  [[ "$(release_designated_requirement "$LEGACY_DESTINATION_APP")" == "$LEGACY_ORIGINAL_REQUIREMENT" ]] \
    || release_die "Legacy UshotApp designated requirement changed after validation."
fi

[[ -z "$(exact_executable_pids "$DESTINATION_EXECUTABLE")" ]] \
  || release_die "Current Ushot relaunched before the backup transaction; refusing to move a running app."
[[ -z "$(exact_executable_pids "$LEGACY_DESTINATION_EXECUTABLE")" ]] \
  || release_die "Legacy UshotApp relaunched before the backup transaction; refusing to move a running app."

if path_exists "$DESTINATION_APP"; then
  [[ "$(release_file_id "$BACKUP_ROOT")" == "$BACKUP_ROOT_FILE_ID" ]] \
    || release_die "Backup directory identity changed before moving current Ushot."
  ! path_exists "$CURRENT_BACKUP_APP" \
    || release_die "Current Ushot recovery path became occupied: $CURRENT_BACKUP_APP"
  [[ -z "$(exact_executable_pids "$DESTINATION_EXECUTABLE")" ]] \
    || release_die "Current Ushot relaunched immediately before its backup move."
  [[ "$(release_file_id "$DESTINATION_APP")" == "$CURRENT_ORIGINAL_FILE_ID" ]] \
    || release_die "Installed Ushot changed after validation; refusing to move it."
  CURRENT_MOVE_BEGAN="YES"
  /bin/mv "$DESTINATION_APP" "$CURRENT_BACKUP_APP"
  CURRENT_MOVED="YES"
  [[ "$(release_file_id "$CURRENT_BACKUP_APP")" == "$CURRENT_ORIGINAL_FILE_ID" ]] \
    || release_die "Current Ushot backup did not preserve the validated directory identity."
  validate_current_recovery_app "$CURRENT_BACKUP_APP" "$SOURCE_TEAM" "$CURRENT_ORIGINAL_REQUIREMENT"
  [[ -z "$(exact_executable_pids "$DESTINATION_EXECUTABLE")" ]] \
    || release_die "A current Ushot process appeared during its backup move; rolling back."
fi

if path_exists "$LEGACY_DESTINATION_APP"; then
  [[ "$(release_file_id "$BACKUP_ROOT")" == "$BACKUP_ROOT_FILE_ID" ]] \
    || release_die "Backup directory identity changed before moving legacy UshotApp."
  ! path_exists "$LEGACY_BACKUP_APP" \
    || release_die "Legacy UshotApp recovery path became occupied: $LEGACY_BACKUP_APP"
  [[ -z "$(exact_executable_pids "$LEGACY_DESTINATION_EXECUTABLE")" ]] \
    || release_die "Legacy UshotApp relaunched before its backup move; refusing to move a running app."
  [[ "$(release_file_id "$LEGACY_DESTINATION_APP")" == "$LEGACY_ORIGINAL_FILE_ID" ]] \
    || release_die "Legacy UshotApp changed after validation; refusing to move it."
  LEGACY_MOVE_BEGAN="YES"
  /bin/mv "$LEGACY_DESTINATION_APP" "$LEGACY_BACKUP_APP"
  LEGACY_MOVED="YES"
  [[ "$(release_file_id "$LEGACY_BACKUP_APP")" == "$LEGACY_ORIGINAL_FILE_ID" ]] \
    || release_die "Legacy UshotApp backup did not preserve the validated directory identity."
  validate_legacy_local_app "$LEGACY_BACKUP_APP" "$SOURCE_TEAM"
  [[ "$(release_designated_requirement "$LEGACY_BACKUP_APP")" == "$LEGACY_ORIGINAL_REQUIREMENT" ]] \
    || release_die "Legacy UshotApp backup designated requirement changed during its move."
  [[ -z "$(exact_executable_pids "$LEGACY_DESTINATION_EXECUTABLE")" ]] \
    || release_die "A legacy UshotApp process appeared during its backup move; rolling back."
fi

[[ ! -e "$DESTINATION_APP" && ! -L "$DESTINATION_APP" ]] \
  || release_die "Ushot destination became occupied before installation: $DESTINATION_APP"
[[ "$(release_file_id "$STAGING_ROOT")" == "$STAGING_ROOT_FILE_ID" \
    && "$(release_file_id "$STAGED_APP")" == "$STAGED_FILE_ID" \
    && "$(release_inode "$STAGED_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME")" == "$STAGED_EXECUTABLE_INODE" ]] \
  || release_die "Staged Ushot identity changed immediately before installation."
[[ -z "$(exact_executable_pids "$DESTINATION_EXECUTABLE")" \
    && -z "$(exact_executable_pids "$LEGACY_DESTINATION_EXECUTABLE")" ]] \
  || release_die "An old exact-path Ushot process appeared before installing the replacement."
NEW_MOVE_BEGAN="YES"
/bin/mv "$STAGED_APP" "$DESTINATION_APP"
NEW_INSTALLED="YES"
[[ "$(release_file_id "$DESTINATION_APP")" == "$STAGED_FILE_ID" ]] \
  || release_die "Atomic install did not preserve the validated staged directory identity."
[[ "$(release_inode "$DESTINATION_EXECUTABLE")" == "$STAGED_EXECUTABLE_INODE" ]] \
  || release_die "Atomic install did not preserve the validated executable identity."

validate_replacement_recovery_app \
  "$DESTINATION_APP" \
  "$SOURCE_VERSION" \
  "$SOURCE_BUILD" \
  "$SOURCE_TEAM" \
  "$SOURCE_REQUIREMENT" \
  "$SOURCE_BINARY_SHA"
/usr/bin/diff -qr --no-dereference "$SOURCE_APP" "$DESTINATION_APP" >/dev/null \
  || release_die "Installed app does not match the fully validated staged source."
INSTALLED_BINARY_SHA="$(release_sha256 "$DESTINATION_APP/Contents/MacOS/$USHOT_EXECUTABLE_NAME")"
[[ "$SOURCE_BINARY_SHA" == "$INSTALLED_BINARY_SHA" ]] \
  || release_die "Installed executable does not match the local-signed artifact."

launch_exact_app "$DESTINATION_APP" "$DESTINATION_EXECUTABLE" "Installed Ushot" \
  || release_die "Installed Ushot did not remain running; the installer will restore the previous app state."

INSTALL_SUCCEEDED="YES"
if /bin/rmdir "$STAGING_ROOT"; then
  STAGING_ROOT=""
  STAGING_ROOT_FILE_ID=""
  STAGED_APP=""
else
  release_warn "Installed Ushot successfully, but the empty staging directory could not be removed: $STAGING_ROOT"
fi
if [[ "$CURRENT_MOVED" != "YES" && "$LEGACY_MOVED" != "YES" ]]; then
  if /bin/rmdir "$BACKUP_ROOT"; then
    BACKUP_ROOT=""
    BACKUP_ROOT_FILE_ID=""
  else
    release_warn "Installed Ushot successfully, but the empty backup directory could not be removed: $BACKUP_ROOT"
  fi
fi

release_log "Installed stable local Ushot: $DESTINATION_APP"
release_log "Version: $SOURCE_VERSION ($SOURCE_BUILD)"
release_log "Team identifier: $SOURCE_TEAM"
release_log "Designated requirement: $SOURCE_REQUIREMENT"
release_log "Executable SHA-256: $INSTALLED_BINARY_SHA"
if [[ "$CURRENT_MOVED" == "YES" ]]; then
  release_log "Recoverable previous Ushot backup: $CURRENT_BACKUP_APP"
fi
if [[ "$LEGACY_MOVED" == "YES" ]]; then
  release_log "Recoverable legacy UshotApp backup: $LEGACY_BACKUP_APP"
fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_local_main
fi
