#!/bin/bash
set -euo pipefail
set +x
ulimit -c 0
unset SPARKLE_ED25519_PRIVATE_KEY SPARKLE_PRIVATE_KEY PRIVATE_KEY DERIVED_PUBLIC_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

BACKUP_PATH=""
EXPECTED_BACKUP_SHA256=""
ASSETS_DIRECTORY=""

usage() {
  printf '%s\n' \
    "usage: $0 --backup /absolute/path/key.backup.enc --expected-backup-sha256 SHA256 --assets-directory /absolute/path/to/artifacts"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP_PATH="${2:?--backup requires a value}"; shift 2 ;;
    --expected-backup-sha256) EXPECTED_BACKUP_SHA256="${2:?--expected-backup-sha256 requires a value}"; shift 2 ;;
    --assets-directory) ASSETS_DIRECTORY="${2:?--assets-directory requires a value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) release_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$BACKUP_PATH" && -n "$EXPECTED_BACKUP_SHA256" && -n "$ASSETS_DIRECTORY" ]] \
  || { usage >&2; exit 1; }
[[ "$BACKUP_PATH" == /* ]] \
  || release_die "Encrypted backup path must be absolute."
[[ "$EXPECTED_BACKUP_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || release_die "Expected backup SHA-256 must contain exactly 64 lowercase hexadecimal characters."

BACKUP_PARENT="$(dirname "$BACKUP_PATH")"
[[ -d "$BACKUP_PARENT" && ! -L "$BACKUP_PARENT" ]] \
  || release_die "Encrypted backup parent must be an existing real directory."
CANONICAL_BACKUP_PARENT="$(cd "$BACKUP_PARENT" && pwd -P)"
CANONICAL_BACKUP="$CANONICAL_BACKUP_PARENT/$(basename "$BACKUP_PATH")"
[[ "$BACKUP_PATH" == "$CANONICAL_BACKUP" ]] \
  || release_die "Encrypted backup path must not traverse symbolic links."
[[ -f "$CANONICAL_BACKUP" && ! -L "$CANONICAL_BACKUP" ]] \
  || release_die "Encrypted backup must be a regular, non-symbolic-link file."
[[ "$(stat -f '%u' "$CANONICAL_BACKUP")" == "$(id -u)" ]] \
  || release_die "Encrypted backup must be owned by the current user."
[[ "$(stat -f '%Lp' "$CANONICAL_BACKUP")" == "600" ]] \
  || release_die "Encrypted backup permissions must be exactly 0600."
release_validate_openssl_salted_ciphertext "$CANONICAL_BACKUP"
ACTUAL_BACKUP_SHA256="$(release_sha256 "$CANONICAL_BACKUP")"
[[ "$ACTUAL_BACKUP_SHA256" == "$EXPECTED_BACKUP_SHA256" ]] \
  || release_die "Encrypted backup SHA-256 does not match the independently recorded value."

[[ "$ASSETS_DIRECTORY" == /* ]] \
  || release_die "Release assets directory must be absolute."
ASSETS_PARENT="$(dirname "$ASSETS_DIRECTORY")"
[[ -d "$ASSETS_PARENT" && ! -L "$ASSETS_PARENT" ]] \
  || release_die "Release assets parent must be an existing real directory."
CANONICAL_ASSETS_PARENT="$(cd "$ASSETS_PARENT" && pwd -P)"
CANONICAL_ASSETS_DIRECTORY="$CANONICAL_ASSETS_PARENT/$(basename "$ASSETS_DIRECTORY")"
[[ "$ASSETS_DIRECTORY" == "$CANONICAL_ASSETS_DIRECTORY" ]] \
  || release_die "Release assets path must not traverse symbolic links."
[[ -d "$CANONICAL_ASSETS_DIRECTORY" && ! -L "$CANONICAL_ASSETS_DIRECTORY" ]] \
  || release_die "Release assets directory must be a real directory."

DRILL_VERSION="0.1.3"
DRILL_BUILD="4"
[[ "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_VERSION" == "$DRILL_VERSION" \
    && "$USHOT_SIGNED_FEED_VALIDATION_TRANSITION_BUILD" == "$DRILL_BUILD" ]] \
  || release_die "Recovery-drill identity constants drifted from the fixed 0.1.3 (build 4) artifacts."
DRILL_TAG="v$DRILL_VERSION"
"$SCRIPT_DIR/validate-release-assets.sh" \
  --directory "$CANONICAL_ASSETS_DIRECTORY" \
  --mode public-adhoc \
  --version "$DRILL_VERSION" \
  --build-number "$DRILL_BUILD" \
  --tag "$DRILL_TAG"
if ! { : < /dev/tty; } 2>/dev/null; then
  release_die "A controlling terminal is required for OpenSSL's hidden password prompt."
fi

umask 077
WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/ushot-sparkle-key-recovery.XXXXXX")"
chmod 700 "$WORKSPACE"
PRIVATE_KEY=""
DERIVED_PUBLIC_KEY=""
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  unset PRIVATE_KEY DERIVED_PUBLIC_KEY
  if [[ -n "${WORKSPACE:-}" && -d "$WORKSPACE" && ! -L "$WORKSPACE" ]]; then
    rm -rf -- "$WORKSPACE"
  fi
  return "$status"
}
signal_exit() {
  local status="$1"
  trap - HUP INT TERM
  exit "$status"
}
trap cleanup EXIT
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

TOOLS_ROOT="$WORKSPACE/tools"
mkdir -m 700 "$TOOLS_ROOT"
SPARKLE_BIN="$(TOOLS_ROOT="$TOOLS_ROOT" "$SCRIPT_DIR/download-sparkle-tools.sh" | tail -n 1)"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[[ -x "$GENERATE_APPCAST" && -x "$SIGN_UPDATE" ]] \
  || release_die "Fresh checksum-pinned Sparkle tools are incomplete."

release_log "Enter the encrypted-backup password at OpenSSL's hidden terminal prompt. Never send it to another person or process."
PRIVATE_KEY="$(
  /usr/bin/openssl enc \
    -d \
    -aes-256-cbc \
    -pbkdf2 \
    -iter 600000 \
    -md sha256 \
    -in "$CANONICAL_BACKUP" \
    < /dev/tty
)"
[[ -n "$PRIVATE_KEY" ]] \
  || release_die "Encrypted backup decrypted to an empty Sparkle private key."
export -n PRIVATE_KEY
DERIVED_PUBLIC_KEY="$(
  printf '%s' "$PRIVATE_KEY" | "$SCRIPT_DIR/derive-sparkle-public-key.swift"
)"
[[ "$DERIVED_PUBLIC_KEY" == "$USHOT_SPARKLE_PUBLIC_ED_KEY" ]] \
  || release_die "Recovered private key does not match Ushot's embedded Sparkle public key."
unset DERIVED_PUBLIC_KEY

DRILL_ROOT="$WORKSPACE/drill"
DRILL_HOME="$WORKSPACE/home"
mkdir -m 700 "$DRILL_ROOT" "$DRILL_HOME"
ARCHIVE_NAME="$USHOT_PRODUCT_NAME-$DRILL_VERSION-$USHOT_ARCHITECTURE.zip"
ARCHIVE_PATH="$CANONICAL_ASSETS_DIRECTORY/$ARCHIVE_NAME"
DRILL_ARCHIVE="$DRILL_ROOT/$ARCHIVE_NAME"
DRILL_NOTES="$DRILL_ROOT/$USHOT_PRODUCT_NAME-$DRILL_VERSION-$USHOT_ARCHITECTURE.md"
DRILL_APPCAST="$DRILL_ROOT/appcast.xml"
ditto "$ARCHIVE_PATH" "$DRILL_ARCHIVE"
printf '%s\n' \
  '## Ushot key recovery drill' \
  '' \
  '- Disposable recovered-key signing verification.' \
  > "$DRILL_NOTES"

printf '%s' "$PRIVATE_KEY" | \
  HOME="$DRILL_HOME" "$GENERATE_APPCAST" \
    --ed-key-file - \
    --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "https://ushot-key-recovery.invalid/$DRILL_TAG/" \
    --embed-release-notes \
    --versions "$DRILL_BUILD" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$DRILL_APPCAST" \
    "$DRILL_ROOT" \
    > "$WORKSPACE/generate-appcast.log" 2>&1
[[ -s "$DRILL_APPCAST" ]] \
  || release_die "Sparkle did not create the disposable recovery appcast."
release_require_command xmllint
xmllint --noout "$DRILL_APPCAST"
ENCLOSURE_URL="$(xmllint --xpath "string((//*[local-name()='enclosure'])[1]/@url)" "$DRILL_APPCAST")"
[[ "$ENCLOSURE_URL" == "https://ushot-key-recovery.invalid/$DRILL_TAG/$ARCHIVE_NAME" ]] \
  || release_die "Disposable recovery appcast escaped its reserved .invalid origin."
if LC_ALL=C grep -Eq 'github\.com|ischeneycc\.github\.io' "$DRILL_APPCAST"; then
  release_die "Disposable recovery appcast contains a production-capable origin."
fi
ENCLOSURE_SIGNATURE="$(xmllint --xpath "string((//*[local-name()='enclosure'])[1]/@*[local-name()='edSignature'])" "$DRILL_APPCAST")"
[[ -n "$ENCLOSURE_SIGNATURE" ]] \
  || release_die "Disposable recovery appcast has no archive EdDSA signature."

printf '%s' "$PRIVATE_KEY" | \
  "$SIGN_UPDATE" \
    --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
    --verify \
    --ed-key-file - \
    "$DRILL_ARCHIVE" \
    "$ENCLOSURE_SIGNATURE" \
    > "$WORKSPACE/verify-archive.log" 2>&1 \
  || release_die "Recovered key could not verify the generated archive signature."
printf '%s' "$PRIVATE_KEY" | \
  "$SIGN_UPDATE" \
    --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
    --verify \
    --ed-key-file - \
    "$DRILL_APPCAST" \
    > "$WORKSPACE/verify-appcast.log" 2>&1 \
  || release_die "Recovered key could not verify the generated signed appcast."

TAMPERED_ARCHIVE="$WORKSPACE/tampered-$ARCHIVE_NAME"
ditto "$DRILL_ARCHIVE" "$TAMPERED_ARCHIVE"
printf '%s' 'ushot-key-recovery-tamper' >> "$TAMPERED_ARCHIVE"
if printf '%s' "$PRIVATE_KEY" | \
  "$SIGN_UPDATE" \
    --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
    --verify \
    --ed-key-file - \
    "$TAMPERED_ARCHIVE" \
    "$ENCLOSURE_SIGNATURE" \
    > "$WORKSPACE/verify-tampered-archive.log" 2>&1; then
  release_die "Sparkle unexpectedly accepted a tampered archive."
fi

TAMPERED_APPCAST="$WORKSPACE/tampered-appcast.xml"
/usr/bin/sed 's/Ushot/Ush0t/g' "$DRILL_APPCAST" > "$TAMPERED_APPCAST"
cmp -s "$DRILL_APPCAST" "$TAMPERED_APPCAST" \
  && release_die "Appcast tamper fixture did not change the signed bytes."
if printf '%s' "$PRIVATE_KEY" | \
  "$SIGN_UPDATE" \
    --account "$USHOT_SPARKLE_KEY_ACCOUNT" \
    --verify \
    --ed-key-file - \
    "$TAMPERED_APPCAST" \
    > "$WORKSPACE/verify-tampered-appcast.log" 2>&1; then
  release_die "Sparkle unexpectedly accepted a tampered signed appcast."
fi

ARCHIVE_SHA256="$(release_sha256 "$DRILL_ARCHIVE")"
APPCAST_SHA256="$(release_sha256 "$DRILL_APPCAST")"
unset PRIVATE_KEY
release_log "Recovered-key signing drill passed without creating a plaintext key file."
printf 'version=%s\nbuild=%s\nbackup_sha256=%s\narchive_sha256=%s\nappcast_sha256=%s\nresult=PASS\n' \
  "$DRILL_VERSION" \
  "$DRILL_BUILD" \
  "$ACTUAL_BACKUP_SHA256" \
  "$ARCHIVE_SHA256" \
  "$APPCAST_SHA256"
